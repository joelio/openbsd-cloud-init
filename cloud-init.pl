#!/usr/bin/env perl

# Copyright (c) 2015 Pierre-Yves Ritschard

# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:

# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

use CPAN::Meta::YAML;
use HTTP::Tiny;
use File::Path qw(make_path);
use File::Temp qw(tempfile);

use strict;

sub get_metadata {
  my ($host, $type) = @_;
  my $response = HTTP::Tiny->new->get("http://$host/latest/$type");
  return unless $response->{success};
  return $response->{content};
}

sub get_host {
  open my $fh, "<", "/var/db/dhclient.leases.vio0";
  my $host;
  while (<$fh>) {
    $host = $1 if /dhcp-server-identifier (.*);$/;
  }
  close $fh;
  return $host;
}

sub install_pubkeys {
  my $pubkeys = shift;

  make_path('/root/.ssh', { verbose => 0, mode => 0700 });
  open my $fh, ">>", "/root/.ssh/authorized_keys";
  printf $fh "#-- key added by cloud-init at your request --#\n";
  printf $fh "%s\n", $pubkeys;
  close $fh;
}

sub apply_user_data {
  my $data = shift;

  if (defined($data->{fqdn})) {
    open my $fh, ">", "/etc/myname";
    printf $fh "%s\n", $data->{fqdn};
    close $fh;
    system("hostname " . $data->{fqdn});
  }

  if (defined($data->{manage_etc_hosts}) &&
      defined($data->{fqdn}) &&
      $data->{manage_etc_hosts} eq 'true') {
    open my $fh, ">>", "/etc/hosts";
    my ($shortname) = split(/\./, $data->{fqdn});
    printf $fh "127.0.1.1 %s %s\n", $shortname, $data->{fqdn};
    close $fh;
  }
}

sub cloud_init {
    my $host = get_host();
    my $data = get_metadata($host, 'user-data');

    my $pubkeys = get_metadata($host, 'public-keys');
    chomp($pubkeys);
    install_pubkeys $pubkeys;

    if (defined($data)) {
        if ($data =~ /^#cloud-config/) {
            $data = CPAN::Meta::YAML->read_string($data)->[0];
            apply_user_data $data;
        } elsif ($data =~ /^#\!/) {
            my ($fh, $filename) = tempfile("/tmp/cloud-config-XXXXXX");
            print $fh $data;
            chmod(0700, $fh);
            close $fh;
            system("sh -c \"$filename && rm $filename\"");
        }
    }
}

sub action_deploy {
    #-- rc.firsttime stub
    open my $fh, ">>", "/etc/rc.firsttime";
    print $fh <<'EOF';
# run cloud-init
path=/usr/local/libdata/cloud-init.pl
echo -n "exoscale first boot: "
perl $path cloud-init && echo "done."
EOF
    close $fh;

    #-- remove generated keys and seeds
    unlink glob "/etc/ssh/ssh_host*";
    unlink "/etc/random.seed";
    unlink "/var/db/host.random";
    unlink "/etc/isakmpd/private/local.key";
    unlink "/etc/isakmpd/local.pub";
    unlink "/etc/iked/private/local.key";
    unlink "/etc/isakmpd/local.pub";

    #-- remove cruft
    unlink "/tmp/*";
    unlink "/var/db/dhclient.leases.vio0";

    #-- disable root password
    system("chpass -a 'root:*:0:0:daemon:0:0:Charlie &:/root:/bin/ksh'")
}

#-- main
my ($action) = @ARGV;

action_deploy if ($action eq 'deploy');
cloud_init if ($action eq 'cloud-init');
