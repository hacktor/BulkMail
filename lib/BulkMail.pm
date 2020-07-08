package BulkMail;
use Dancer ':syntax';
use Dancer::Plugin::Database;
use HTML::Entities;
use DBI;

our $VERSION = '0.1';

sub connect_db {
  my $db = DBI->connect("dbi:SQLite:dbname=".config->{sqlite}{db}) or
     die $DBI::errstr;

  return $db;
}

sub init_db {
    my $db = connect_db();

    # slurp sql schema
    my $schema = do { local(@ARGV,$/) = config->{sqlite}{schema}; <>};
    $db->do($schema) or die $db->errstr;
    return $db;
}

get '/mailing/:key' => sub {

    my $db = connect_db();
    my $stm = $db->prepare("select * from mbox where key = ?");
    $stm->execute(param('key'));
    if (my $row = $stm->fetchrow_hashref()) {

        my @froms;
        for my $from (@{config->{froms}}) {
            push @froms, encode_entities($from);
        }
        session key => param('key');
        session row => $row;
        template 'mailing', {subject => encode_entities($row->{subject}),
                             from => encode_entities($row->{from_address}),
                             date => encode_entities($row->{date}),
                             body => encode_entities($row->{body}),
                             froms => \@froms};
    } else {
        template 'index', { error => "Key niet gevonden" };
    }
};

post '/recipients' => sub {

    if (defined params->{afz}) {

        # update sqlite database
        my $db = connect_db();
        my $stm = $db->prepare("update mbox set new_from_address = ? where key = ?");
        unless ($stm->execute(param('afz'),session('key'))) {
            template 'index', { error => "Fout in update afzender adres" };
            return;
        }
        session->{row}{new_from_address} = param('afz');

        my $row = session('row');
        template 'recipients', {subject => encode_entities($row->{subject}),
                                new_from => encode_entities($row->{new_from_address})};
    } else {
        template 'index', { error => "Fout in nieuw afzender adres" };
    }
};

any ['get', 'post'] => '/' => sub {
    template 'index';
};

true;
