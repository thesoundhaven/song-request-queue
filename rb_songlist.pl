#!/usr/bin/env perl

use strict;
use warnings;
use Mojo::JSON::MaybeXS;
use Mojolicious::Lite;
use Crypt::Eksblowfish::Bcrypt qw(en_base64 bcrypt);
use Digest::MD5 'md5';
use List::Util ();
use Mojo::Pg;
use Text::CSV 'csv';
use Time::Seconds;
use experimental 'signatures';

plugin 'Config';

app->secrets(app->config->{secrets}) if app->config->{secrets};

app->sessions->default_expiration(ONE_WEEK);

helper pg => sub ($c) { state $pg = Mojo::Pg->new($c->config('pg')) };

my $migrations_file = app->home->child('rb_songlist.sql');
app->pg->auto_migrate(1)->migrations->name('rb_songlist')->from_file($migrations_file);

helper hash_password => sub ($c, $password, $username) {
  my $remote_address = $c->tx->remote_address // '127.0.0.1';
  my $salt = en_base64 md5 join '$', $username, \my $dummy, time, $remote_address;
  my $hash = bcrypt $password, sprintf '$2a$08$%s', $salt;
  return $hash;
};

helper user_is_admin => sub ($c, $user_id) {
  my $query = 'SELECT "id" FROM "users" WHERE "id"=$1';
  my $exists = $c->pg->db->query($query, $user_id)->hashes->first;
  return undef unless defined $exists;
  return 1;
};

helper valid_bot_key => sub ($c, $bot_key) {
  return 1 if defined $bot_key
    and List::Util::any { $_ eq $bot_key } @{$c->config('bot_keys') // []};
  return 0;
};

helper import_from_csv => sub ($c, $file) {
  my $songs = csv(in => $file, encoding => 'UTF-8', detect_bom => 1)
    or die Text::CSV->error_diag;
  my $db = $c->pg->db;
  my $tx = $db->begin;
  foreach my $song (@$songs) {
    my $query = <<'EOQ';
INSERT INTO "songs" ("title","artist","album","track","source","duration")
VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT DO NOTHING
EOQ
    my @params = @$song{'song title','artist','album name','track #','source','duration'};
    $db->query($query, @params);
  }
  $tx->commit;
  return 1;
};

helper delete_song => sub ($c, $song_id) {
  my $query = 'DELETE FROM "songs" WHERE "id"=$1 RETURNING "title"';
  my $deleted = $c->pg->db->query($query, $song_id)->arrays->first;
  return defined $deleted ? $deleted->[0] : undef;
};

helper queue_details => sub ($c) {
  my $query = <<'EOQ';
SELECT "songs"."id" AS "song_id", "title", "artist", "album", "track",
"source", "duration", "requested_by", "requested_at", "position"
FROM "queue" INNER JOIN "songs" ON "songs"."id"="queue"."song_id"
ORDER BY "queue"."position"
EOQ
  return $c->pg->db->query($query)->hashes;
};

helper queue_song => sub ($c, $song_id, $requested_by) {
  my $query = <<'EOQ';
INSERT INTO "queue" ("song_id","requested_by","position")
VALUES ($1,$2,COALESCE((SELECT MAX("position") FROM "queue"),0)+1)
EOQ
  return $c->pg->db->query($query, $song_id, $requested_by)->rows;
};

helper unqueue_song => sub ($c, $position) {
  my $query = 'DELETE FROM "queue" WHERE "position"=$1 RETURNING "song_id"';
  my $deleted = $c->pg->db->query($query, $position)->arrays->first;
  return defined $deleted ? $deleted->[0] : undef;
};

helper clear_queue => sub ($c) {
  my $query = 'DELETE FROM "queue" WHERE true';
  return $c->pg->db->query($query)->rows;
};

helper search_songs => sub ($c, $search) {
  my $query = <<'EOQ';
SELECT * FROM "songs"
WHERE to_tsvector('english', title || ' ' || artist || ' ' || album) @@ to_tsquery($1)
EOQ
  return $c->pg->db->query($query, $search)->hashes;
};

helper song_details => sub ($c, $song_id) {
  my $query = 'SELECT * FROM "songs" WHERE "id"=$1';
  return $c->pg->db->query($query, $song_id)->hashes->first;
};

get '/' => 'index';

get '/admin' => sub ($c) {
  return $c->redirect_to('/login') unless defined $c->session->{user_id};
  $c->render;
};

get '/login';
post '/login' => sub ($c) {
  my $username = $c->param('username');
  my $password = $c->param('password');
  return $c->render(text => 'Missing parameters')
    unless defined $username and defined $password;
  
  my $query = <<'EOQ';
SELECT "id", "username", "password_hash" FROM "users" WHERE "username"=$1
EOQ
  my $user = $c->pg->db->query($query, $username)->hashes->first;
  return $c->render(text => 'Login failed') unless defined $user
    and bcrypt($password, $user->{password_hash}) eq $user->{password_hash};
  
  $c->session->{user_id} = $user->{id};
  $c->session->{username} = $user->{username};
  $c->redirect_to('/');
};
any '/logout' => sub ($c) {
  delete @{$c->session}{'user_id','username'};
  $c->session(expires => 1);
  $c->redirect_to('/');
};

get '/set_password';
post '/set_password' => sub ($c) {
  my $username = $c->param('username');
  my $code = $c->param('code');
  my $password = $c->param('password');
  my $verify = $c->param('verify');
  
  return $c->render(text => 'Missing parameters')
    unless defined $username and defined $code and defined $password and defined $verify;
  return $c->render(text => 'Passwords do not match') unless $password eq $verify;
  my $query = <<'EOQ';
SELECT "id" FROM "users" WHERE "username"=$1 AND "password_reset_code"=decode($2, 'hex')
EOQ
  my $user_exists = $c->pg->db->query($query, $username, $code)->arrays->first;
  return $c->render(text => 'Unknown user or invalid code') unless defined $user_exists;
  
  my $hash = $c->hash_password($password, $username);
  $query = <<'EOQ';
UPDATE "users" SET "password_hash"=$1, "password_reset_code"=NULL
WHERE "username"=$2 AND "password_reset_code"=decode($3, 'hex')
EOQ
  my $updated = $c->pg->db->query($query, $hash, $username, $code)->rows;
  return $c->render(text => 'Password set successfully') if $updated > 0;
  $c->render(text => 'Password was not set');
};

get '/songs/search' => sub ($c) {
  my $search = $c->param('query') // '';
  $c->render(json => []) unless length $search;
  my $results = $c->search_songs($search);
  $c->render(json => $results);
};

get '/songs/:song_id' => sub ($c) {
  my $song_id = $c->param('song_id');
  my $details = $c->song_details($song_id);
  $c->render(json => $details);
};

get '/queue' => sub ($c) {
  my $queue_details = $c->queue_details;
  $c->render(json => $queue_details);
};

# Admin functions
group {
  under '/' => sub ($c) {
    my $user_id = $c->session->{user_id};
    if (defined $user_id and $c->user_is_admin($user_id)) {
      $c->stash(user_id => $user_id, admin => 1);
      return 1;
    }
    my $bot_key = $c->param('bot_key');
    if (defined $bot_key and $c->valid_bot_key($bot_key)) {
      $c->stash(bot => 1);
      return 1;
    }
    $c->render(text => 'Access denied', status => 403);
    return 0;
  };
  
  post '/songs/import' => sub ($c) {
    return $c->render(text => 'Access denied', status => 403) unless $c->stash('admin');
    my $upload = $c->req->upload('songlist');
    return $c->render(text => 'No songlist provided.') unless defined $upload;
    my $name = $upload->filename;
    $c->import_from_csv(\($upload->asset->slurp));
    $c->render(text => "Import of $name successful.");
  };
  
  del '/songs/:song_id' => sub ($c) {
    return $c->render(text => 'Access denied', status => 403) unless $c->stash('admin');
    my $song_id = $c->param('song_id');
    my $deleted_title = $c->delete_song($song_id);
    return $c->render(text => "Invalid song ID $song_id") unless defined $deleted_title;
    $c->render(text => "Deleted song $song_id '$deleted_title'");
  };
  
  any '/queue/add' => sub ($c) {
    my $song_id = $c->param('song_id');
    my $song_details;
    if (defined $song_id) {
      $song_details = $c->song_details($song_id);
      return $c->render(text => "Invalid song ID $song_id") unless defined $song_details;
    } else {
      my $search = $c->param('query') // '';
      return $c->render(text => 'No song ID or search query provided.') unless length $search;
      my $search_results = $c->search_songs($search);
      return $c->render(text => 'No matching results.') unless @$search_results;
      $song_details = $search_results->first;
      $song_id = $song_details->{id};
    }
    
    my $requested_by = $c->param('requested_by') // $c->session->{username} // '';
    $c->queue_song($song_id, $requested_by);
    $c->render(text => "Added '$song_details->{title}' to queue (requested by $requested_by)");
  };
  
  del '/queue/:position' => sub ($c) {
    return $c->render(text => 'Access denied', status => 403) unless $c->stash('admin');
    my $position = $c->param('position');
    my $deleted_id = $c->unqueue_song($position);
    $c->render(text => "No song in position $position") unless defined $deleted_id;
    my $deleted_song = $c->song_details($deleted_id);
    $c->render(text => "Removed song '$deleted_song->{title}' from queue position $position");
  };
  
  del '/queue' => sub ($c) {
    return $c->render(text => 'Access denied', status => 403) unless $c->stash('admin');
    my $deleted = $c->clear_queue;
    $c->render(text => "Cleared queue (removed $deleted songs)");
  };
};

app->start;
