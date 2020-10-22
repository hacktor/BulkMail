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
                    my $ct = ($email->header_raw("Content-Type")) ?
                              $email->header_raw("Content-Type") : '';
                    my $ctf = ($email->header_raw("Content-Transfer-Encoding")) ?
                               $email->header_raw("Content-Transfer-Encoding") : '';
                    my $cl = ($email->header_raw("Content-Language")) ?
                              $email->header_raw("Content-Language") : '';
                    my $mv = ($email->header_raw("MIME-Version")) ?
                              $email->header_raw("MIME-Version") : '';

                    eval {
                        $st->execute($key,$ackkey,$email->header_raw("From"),$email->header_raw("Subject"),
                                 $email->header_raw("Date"),$ct,$ctf,$cl,$mv,$email->body);
                    };
                    if ($@) {
                        debug($@);
                        # move the mail to the 'ERROR' folder
                        $imap->expunge if $imap->move( 'ERROR', $msgnum );
                        next;
                    }
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

