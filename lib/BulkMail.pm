package BulkMail;
use Dancer ':syntax';
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
        template 'mailing', { subject => $row->{subject}, from => $row->{from_address}, date => $row->{date} };
    } else {
        template 'index';
    }
};

any ['get', 'post'] => '/' => sub {
    template 'index';
};

true;
