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
use experimental 'signatures';

plugin 'Config';

app->secrets(app->config->{secrets}) if app->config->{secrets};

my $migrations_file = app->home->child('rb_songlist.sql');
app->pg->auto_migrate(1)->migrations->name('rb_songlist')->from_file($migrations_file);

helper pg => sub ($c) { state $pg = Mojo::Pg->new($c->config('pg')) };

helper hash_password => sub ($c, $password, $username) {
  my $remote_address = $c->tx->remote_address // '127.0.0.1';
  my $salt = en_base64 md5 join '$', $username, \my $dummy, time, $remote_address;
  my $hash = bcrypt $password, sprintf '$2a$08$%s', $salt;
  return $hash;
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

get '/' => 'index';
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

post '/import_songlist' => sub ($c) {
  my $upload = $c->req->upload('songlist');
  return $c->render(text => 'No songlist provided.') unless defined $upload;
  my $name = $upload->filename;
  $c->import_from_csv(\($upload->asset->slurp));
  $c->render(text => "Import of $name successful.");
};

get '/find_song' => sub ($c) {
  my $search = $c->param('query') // '';
  $c->render(json => []) unless length $search;
  my $query = <<'EOQ';
SELECT * FROM "songs" WHERE to_tsvector('english', title || ' ' || artist || ' ' || album) @@ to_tsquery($1)
EOQ
  my $results = $c->pg->db->query($query, $search)->hashes;
  $c->render(json => $results);
};

app->start;
