# Apache::Centipaid
# Version $Revision: 1.3 $
#
# $Id: Centipaid.pm,v 1.3 2003/01/25 18:20:54 root Exp root $
#
# Written by Adonis El Fakih (adonis@aynacorp.com) Copyright 2002
# 
# This perl module allows site administrators to integrate the
# centipaid.com payment system without making changes to their 
# existing website.
#
# centipaid offers a micropayment solution that allows users
# to pay for online access using an internet stamp, inctead of
# paying using a credit card number, which requieres the user 
# to divulge their credit card number to the site operator.
# for more information on the micro-payment system please visit
# http://www.centipaid.com/
# 
#
# This module may be distributed under the GPL v2 or later.
#
#


package Apache::Centipaid;

use Apache ();
use Apache::Constants qw(OK REDIRECT AUTH_REQUIRED DECLINED FORBIDDEN DECLINED SERVER_ERROR);
use Apache::File;
use IO::Socket;
use Net::hostent;
use DBI;
use CGI::Cookie;



use strict;

$Apache::Centipaid::VERSION = '1.3';

sub need_to_pay($) {
	my $r = shift(@_);
	my $payto = $r->dir_config("acct") || 0;
	my $amount = $r->dir_config("amount") || 0;
	my $duration = $r->dir_config("duration") || 0;
	my $uri =  $r->uri;
	my $access =  $r->dir_config("access") || 0;
	my $domain =  $r->dir_config("domain") || 0;
	my $lang =  $r->dir_config("lang") || "en";
	my $https =  $r->dir_config("https") || "https://pay.centipaid.com";

	$r->content_type('text/html');
	$r->header_out(Location =>"$https/?payto=$payto&amount=$amount&duration=$duration&access=$access&domain=$domain&path=$uri&lang=$lang");
	return REDIRECT;

}


sub to_seconds ($) {
    my $duration = shift(@_);
    my $multi;
    my $seconds;

    if ( $duration =~ /^(\d+)(.+)/ ) {
    	my $num = $1;
	my $ltr = $2;
		if ( lc($ltr) eq "m" ) { $multi = 30*24*60*60;}
		if ( lc($ltr) eq "w" ) { $multi = 7*24*60*60;}
		if ( lc($ltr) eq "d" ) { $multi = 24*60*60;}
		if ( lc($ltr) eq "h" ) { $multi = 60*60;}
		$seconds = $multi * $num;
	}

    return $seconds;

}

sub handler {
   
my ($r) = shift;
my $debug = $r->dir_config("debug") || 0;
my $payto = $r->dir_config("acct") || 0;
my $server = $r->dir_config("authserver") || 0;
my $port = $r->dir_config("authport") || 0;
my $pass = $r->dir_config("pass") || 0;
my $amount = $r->dir_config("amount") || 0;
my $access = $r->dir_config("access") || 0;
my $domain = $r->dir_config("domain") || 0;
my $duration = to_seconds($r->dir_config("duration") || 0);
my $enforce_ip = $r->dir_config("enforce_ip") || 0;


# database variables
my $dbtype = $r->dir_config("dbtype") || "mysql";
my $dbhost = $r->dir_config("dbhost") || "localhost";
my $dbport = $r->dir_config("dbport") || "3306";
my $dbname = $r->dir_config("dbname") || 0;
my $dbuser = $r->dir_config("dbuser") || 0;
my $dbpass = $r->dir_config("dbpass") || 0;

#request info
my $c = $r->connection; 
my $ip = $c->remote_ip;
my %args = $r->args;
my $uri = $r->uri;
my $cookie_name = $r->auth_name . "_". $r->auth_type;
my $prefix = "$$ Apache::Centipaid"; 


# connect to the database
my $dsn = "DBI:$dbtype:database=$dbname;host=$dbhost;port=$dbport";
my $dbh = DBI->connect($dsn,$dbuser,$dbpass);

my $connect_to ="$server:$port";
my $line;
my $and;


#cookie information
my %cookies = CGI::Cookie->parse($r->header_in('Cookie'));
my $cookie;
if ( $cookies{$cookie_name} =~ /$cookie_name=([^;]+)/ ) { $cookie = $1; }

	

#print some stats if debug is on
$r->log_error("$prefix: payto $payto") if $debug >= 2;
$r->log_error("$prefix: server $server") if $debug >= 2;
$r->log_error("$prefix: port $port") if $debug >= 2;
$r->log_error("$prefix: ip $ip") if $debug >= 2;
$r->log_error("$prefix: key rcpt = $args{centipaid_rcpt}") if $debug >= 2;
$r->log_error("$prefix: cookie = $cookie") if $debug >= 2;
$r->log_error("$prefix: uri = ". $r->uri) if $debug >= 2;





# else we need to check if there us any indication that the user has paid
# by checking the variables	
if ( $args{centipaid_rcpt} ) {
	my $rcpt  = $args{centipaid_rcpt};	
	
	$r->log_error("$prefix: Autheticating receipt $rcpt via socket://$payto:$pass\@$connect_to/") if $debug >= 2;
	
	my $auth_server = IO::Socket::INET->new("$connect_to");
   	my $crlf = "\015\012";
   	unless ( $auth_server ) { 
		$r->log_error("Could not connect to $connect_to") if $debug >= 2;
		return;
	}
   
	$auth_server->autoflush(1);
   	print $auth_server "PAYTO:$payto"."$crlf";
   	print $auth_server "PASS:$pass"."$crlf";
   	print $auth_server "RCPT:$rcpt"."$crlf";

	# format the amount in a way that we make sure it becomes a float
	$amount = sprintf("%.6f",$amount);
	while (<$auth_server>) {
		chomp;
		my $received = $_;

		
		$r->log_error("CLIENT:$received") if $debug >= 2;
		
		if ($received =~ /^250 OK PAID(.+)/) {
			# format the paid in a way that we make sure it becomes a float
			my $paid = sprintf("%.6f",$1);
			$r->log_error("Paid [$paid] Amount [$amount]") if $debug >= 5;
			
			# if the amount paid is greater or equal to what 
			# is requiered then it is ok
			if ( $paid >= $amount ) { 
				$r->log_error("$paid  == $amount ") if $debug >= 5;
				
				# insert value in DB
				my $sql =    qq{
						insert into rcpt (rcpt,date,expire,paid,ip,zone) 
						values (
							"$rcpt",NOW(),
							DATE_ADD(NOW(),INTERVAL $duration SECOND),
							$paid,
							"$ip",
							"$cookie_name"
							)
						};
				my $sth =  $dbh->do("$sql");

				# set the cookie so we do not call the server again..
				my $str = CGI::Cookie->new(-name => "$cookie_name",
							   -path=> "$access",
							   -domain => "$domain",
							   -value => "$rcpt",
							   -expires => "+".$duration."s");

				$r->err_headers_out->add('Set-Cookie' => $str);	
				$r->content_type('text/html');
				$r->header_out(Location =>"$uri");
				return REDIRECT;
			}# if paid == amount
			
		}#end if 250
		
		
		if ($received =~ /^500/) {
			# if we get a 500 code then it was an invalid receipt
			$r->log_error("Invalid transaction for receipt $rcpt") if $debug >= 2;

			#send them back to pay
			$r->content_type('text/html');
			$r->header_out(Location =>"$uri");
			return REDIRECT;
			#need_to_pay($r);
		}#end if 500
		
		
   	}# end while	

} elsif ( $cookie ) {

#if there is a cookie, and the cookie is what we are looking for, then
# then this user has been here, and we will check it against valid ones in
# the database..
	my @row;
	
	$r->log_error("$prefix: Autheticating receipt $cookie via db://$dbuser:$dbpass\@$dbhost:$dbport/$dbname/") if $debug >= 2;


	# if the site manager wants to tie the receipt to one ip, he/she can do that to insure that one recipt is used
	# per ip.  THis is not recommended with site that receive a lot of users using proxies, since the ip's may be shared
	# or in cases the user is using a dialup
	if ( $enforce_ip == 1) {$and = "and ip = '$ip'";} 
	
	# select records matching rcpt and within expiry date..
	my $sql = qq{select rcpt,date,expire,paid,ip from rcpt where rcpt="$cookie" and expire >= NOW() $and};

	my $sth = $dbh->prepare($sql);
	$sth->execute or db_err("Unable to execute query \n$sql\n", $dbh->errstr);
	while ( @row = $sth->fetchrow_array ) {	
		my ($rcpt,$date,$expire,$paid,$ip) = @row;
		$r->log_error("$prefix: receipt record found $rcpt,$date,$expire,$paid,$ip") if $debug >= 2;
		return OK;
	}		
	
	
	#if we are at this stage, then the cookie is not valid or not found and we should remove it.. 
	my $str = CGI::Cookie->new(-name => "$cookie_name",
					   -path=> "$access",
					   -domain => "$domain",
					   -value => "",
					   -expires => "-".$duration."s");

	$r->err_headers_out->add('Set-Cookie' => $str);	
	need_to_pay($r);
	
		
	
} else {

# if there is no receipt, and no cookie, then they need to pay
need_to_pay($r);

}#end check for cookie

	
} 

1;

__END__

=head1 NAME

$Revision: 1.3 $

B<Apache::Centipaid> - mod_perl AuthenHandler 


=head1 SYNOPSIS


 #in httpd.com  
 <directory /document_root/path_path>
 AuthName centipaid
 AuthType custom
 PerlAuthenHandler Apache::Centipaid
 require valid-user 

 PerlSetVar acct account_name
 PerlSetVar pass receipt_password
 PerlSetVar amount 0.01
 PerlSetVar duration 1d
 PerlSetVar access /pay_path
 PerlSetVar domain your.domain.name
 PerlSetVar lang en
 PerlSetVar enforce_ip 0

 PerlSetVar https https://pay.centipaid.com   
 PerlSetVar authserver centipaid_receipt_server
 PerlSetvar authport 2021
    
 PerlSetVar dbtype mysql
 PerlSetVar dbhost localhost
 PerlSetVar dbport 3306
 PerlSetVar dbname centipaid_rcpt
 perlSetVar dbuser user
 perlSetVar dbpass pass
 </directory>


=head1 REQUIRES

Perl5.004_04, mod_perl 1.15, IO::Socket, Net::hostent, DBI, DBD, DBD::mysql, CGI::Cookie;


=head1 DESCRIPTION

B<Apache::Centipaid> is a mod_perl Authentication handler used in 
granting access to users wishing to access paid web services, after 
making payment on centipaid.com which process micropayments using
internet stamps. 

Centipaid.com offers websites the flexibility to charge small amounts
of money, also refered to as B<micropayment>, to users wishing to
access to their web services without the complexity of setting up 
e-commerce enabled site, or to deal with expensive credit card 
processing options. Users benefit from not having to reveal their
identity or credit card information everytime they decide to visit a 
website.  Instead, centipaid allows users to simply pay using
a pre-paid internet stamp, by simply uploading the stamp to centipaid's
site. The stamps are valid in all sites using centipaid.com payment
system.

To access a site, recipts are issued by centipaid and are used to track 
valid payments.  This information is captured and processed by the
Apache::Centipaid module.  The information is then stored locally to 
any SQL database installed.  The module relies on DBD/DBI interface
so as long as the database has a DBD interface installed under Perl,
and utilizes SQL to make queries and inserts, then you should be able 
to maintain and track your receipts.

B<How does it work?>
A user visits a website, or a section with a site, that requieres an
accecss fee.  The webserver will intercept the request, and realize that
the user has not made a payment, and hence they are directed to 
centipaid.com to pay for access.  Centipaid will inform the user what 
they are paying for in a standard language, along with the fee associated 
with the access, and the duration of the granted access.

If the user agrees to the terms, s/he proceeds to select an electronic
stamp from his computer that has enough funds to pay for the access.
Centipaid will autheticate the stamp, deduct the access fee, and issue the
user a receipt number.  The user will see a receipt on his page that 
re-iterates the terms, amount paid, and internet stamp balance. A link will 
be also available for the user to click on to be transported back to the
page they came from, along with the receipt number.  Once the user makes
a payment, they are shown the amount paid, the balance left on the card,
and a link back to the page they were trying to access.  Once they press
the link, they are forwarded back to the initial page they tried to 
access.

At this stage, Apache::Centipaid realizes that a rececipt is being submited
as payment.  It takes the receipt number and autheticates with centipaid's 
receipt server to insure that the receipt is a valid one, and that the 
proper funds have been paid.

If the rececipt is valid, then the information is stored locally.  The 
information stored included the ip of the client (for optional enforcment 
of payment tied to ip), amount paid, date of transaction, expiry date, 
and the zone the payment covers.  And since centipaid micropayment system 
is designed to allow users to pay without having to provide username, 
password or any other payment information other than the recipt 
number, it makes the process easy to manage and neither the payer or 
payee have to worry about financial information falling into the wrong 
hands. 

B<How do we track payments?>
When a user makes a payment, the Apache::Centipaid module inserts a cookie 
that contains the receipt number, and it sets the expiry of the cookie
based on the payment B<duration> specified in the configuration file.  
Everytime a user visits protected areas in a site, the cookie is 
inspected, and if it exists it is matched with the receipt database.  if 
it is found, and the expiry date has not been met, then they are granted 
access.  If the receipt is non existent, or past its expiry date, the 
user is prompted to make payment again.  

Please reffer to centipaid.com for the most updated version of this 
module, since other methods of tracking payment may be available.


=head1 List of tokens

=over

=item B<Account and Access Information>

=item B<acct> account_name

 The account number is issued by ceentipaid.com 
 for a given domain name.  This number is unique 
 and it determines who gets paid.
 
=item B<pass> receipt_password

 The password is used only in socket authetication.  
 It does not grant the owner any special access 
 except to be able to query the receipt server for 
 a given receipt number.

=item B<amount> 0.5

 The amount is a real number (float, non-integer) 
 that specifies how much the user must pay to be 
 granted access to the site.  For example amount 
 0.5 will ask the user to pay 50 cents to access the
 site.  The value of amount is in dollar currency.
 
=item B<duration> 1d

 The duration is in the format of NZ where N is an 
 integer number, and Z is either m, w, d, h where 
 m is month, w is week, d is day, and h is hour. So
 if duration is 24h, then it means we grant access 
 for 24 hours, and 2d means 2 days, etc..

=item B<access> /pay_path

 The access specifies what path to protect, and it 
 should be also included in the <Location 
 path_goes_here></Location> as well.  So if we want 
 to protect a whole site then the access is set to 
 "/", while if we want to protect a chat service 
 under /chat then access will be "/chat"
 
=item B<domain> your.domain.name

 This defines the domain which will be returned to.  
 Altough the information is redundant and we can 
 retrieve it from apache itself, we let the admin to
 set it to insure that the return href is properly 
 formed.
 
=item B<lang> en

 This deines the language of the payment page 
 displayed to the user. It is set by the site admin 
 using the two letter ISO 639 code for the language. 
 For example ayna.com requieres the payment info to
 be displayed in arabic on centipaid,  CNN.com will 
 need several sections of its site to show payment 
 requests in different languages. Some of the ISO
 639 language codes are: English (en), Arabic (ar), 
 japanese (ja), Spanish (es), etc..


=item B<enforce_ip> 0

 This tells the module if the website wants to tie
 the receipt to a one ip.  This may be requiered in
 certain casees where the site admin decides that
 access to the site is made only from the ip of
 the machine that makes the payment, as long as the
 machine also holds the receipt cookie.  The valid 
 values are 0 for "do not restrict to ip", and 1 
 for "yes do restrict to the ip".  If ommited, then
 the default is 0.
    

=item B<Authetication server information>

=item B<https> https://pay.centipaid.com

 This should contain the payment url assigned to the
 account number. This defaults to 
 http://pay.centipaid.com


=item B<authserver> centipaid_receipt_server

 This should contain the receipt server assigned to 
 the account number above
 
=item B<authport> 2021

 This should contain the port number of receipt 
 server assigned to the account number above
    

=item B<Local database Information>


=item B<dbtype> mysql

 This dhould be the DBD database string.  For example 
 MySQL's dbtype should be mysql, while postgreSQL is Pg. 
 Reffer to DBD documentation for the correct string.  
 The module defaults to mysql as the installed database 
 if not defined in the configuration file.
 
=item B<dbhost> localhost

 This should the domain name of the database server. 
 The module defaults to localhost if not defined  
 in the configuration file.
 
=item B<dbport> 3306

 This should the port number of the database server. 
 The module defaults to 3306 if not defined  in the 
 configuration file, since the default database type
 is mysql.  For PostgreSQL the port is usually 5432.

=item B<dbname> centipaid_rcpt

 This should be the name of the database you create 
 to hold the recipt information. The module default 
 to centipaid_rcpt default if not defined  in the 
 configuration file.
 
=item B<dbuser> user

 This should be the username of the user that has 
 access to read/write to the database defined in 
 dbname.
 
=item B<dbpass> pass

 This should be the password of the user that has 
 access to read/write to the database defined in 
 dbname.

=back

=head1 Database Schema


B<MySQL> The receipts are stored in a locally accessible database. 
The MySQL database structure is as follows

==begin

CREATE TABLE rcpt (
  rcpt varchar(100) NOT NULL default '',
  date datetime NOT NULL default '0000-00-00 00:00:00',
  expire datetime NOT NULL default '0000-00-00 00:00:00',
  paid double NOT NULL default '0',
  ip varchar(100) default NULL,
  zone varchar(50) NOT NULL default '',
  PRIMARY KEY  (rcpt)
);

==end

where B<rcpt> stores the recipt number, B<date> and B<expire> contain the date the
receipt was issued on the site, and its expiration. B<Paid> contains the amount paid
in float format.  The B<IP> could be used in cases where the site admin decides to tie
a payment to an ip as well as a browser.  We do not reommend this, since people use 
proxy servers, and dynamic IPs.  The B<zone> is used for statistical purposes, where
the website admin can see what sections are being used most.



=head1 TODO

=item B<Apache::DBI support> Use Apache::DBI instead of DBI to use persistent connections


=head1 ACKNOWLEDGEMENTS 

Thanks for Liconln Sten & Doug MacEachern for a great book about B<writing
Apache Modules with Perl and C>. It made writing this module a breeze :)

=head1 AUTHOR

Adonis El Fakih, adonis@aynacorp.com

=head1 SEE ALSO

mod_perl(1). DBI(3)

=cut
