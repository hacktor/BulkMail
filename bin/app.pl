#!/usr/bin/env perl
use utf8;
use Dancer;
use BulkMail;
use threads;
use Mail::IMAPClient;
use Email::Simple;
use IO::Socket::SSL;

# initialize (create if not exists) database
BulkMail::init_db();

# create a thread polling for new mail
threads->create(sub { 

    my $db = BulkMail::connect_db();
    my $st = $db->prepare( config->{sqlite}{insert} );

    for (;;) {
        eval {
            my $imap = Mail::IMAPClient->new(
                Server   => config->{imap}{host},
                User     => config->{imap}{user},
                Password => config->{imap}{pass},
                Ssl => 1,
                Uid => 1,
                SSL_ca_file => config->{imap}{ca});

            if ($imap->select('INBOX')) {
        
                my $msgnums = $imap->messages; #array
                foreach my $msgnum (@$msgnums) {
        
                    my $email = Email::Simple->new($imap->message_string($msgnum));
                    my $key = makeKey();
                    my $ackkey = makeKey();
                    $st->execute($key,$ackkey,$email->header("From"),$email->header("Subject"),$email->header("Date"),$email->header("Content-Type"),$email->header("Content-Transfer-Encoding"),$email->header("Content-Language"),$email->header("MIME-Version"),$email->body);
                    BulkMail::sendReceipt($email,$key);

                    # move the mail to the 'DONE' folder
                    $imap->expunge if $imap->move( 'DONE', $msgnum );
        
                }

            } elsif (not defined $imap) {
                warning("IMAP connection fail");
            } else {
                warning("INBOX not found");
            }
            $imap->logout if $imap;
        };
        warn($@) if $@;
        sleep 30;
    }
})->detach();

# create another thread polling for authorized mailings
threads->create(sub {

    my $db = BulkMail::connect_db();
    my $stm = $db->prepare( config->{sqlite}{get_mailings} );

    for (;;) {
        # get mailings with status 0
        $stm->execute(0);
        BulkMail::mailing($_) for $stm->fetchrow_hashref;
        sleep 60;
    }
})->detach();

dance;

### helper subs ###

sub makeKey {
    my @chars = ('0'..'9', 'A'..'Z');
    my $len = 64;
    my $string;
    while($len--){ $string .= $chars[rand @chars] };
    $string;
}

