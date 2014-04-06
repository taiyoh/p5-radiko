package Radiko;
use 5.008005;
use strict;
use warnings;

our $VERSION = "0.01";

use File::Temp qw/tempdir tempfile/;
use Furl;
use MIME::Base64 'encode_base64';

use Class::Accessor::Lite::Lazy (
    rw_lazy => [
        qw/authkey_file auth1_fms auth2_fms stream_url/,
        {
            workdir    => sub { tempdir(CLEANUP => 1) },
            rtmpdump   => sub {
                my $cmd = `which rtmpdump` or die "require rtmpdump";
                chomp $cmd;
                $cmd
            },
            swfextract => sub {
                my $cmd = `which swfextract` or die "require swfextract. install swftools";
                chomp $cmd;
                $cmd
            },
            ffmpeg => sub {
                my $cmd = `which ffmpeg` or die "require ffmpeg";
                chomp $cmd;
                $cmd;
            },
            url => sub { 'https://radiko.jp/v2' },
            api => sub { shift->url . '/api' },
            swf => sub { 'http://radiko.jp/player/swf/player_3.0.0.01.swf' },
            rtmpdump_opt => sub { +{ } },
            ffmpeg_opt   => sub { +{ } }
        }
    ],
    new => 1,
    ro => [qw/channel/],

);

my $furl = Furl->new;

sub _build_authkey_file {
    my $self = shift;
    my ($authfile, $playerfile);
    {
        my $res = $furl->get($self->swf);
        die "failed to download swf/player" if !$res->is_success;
        my ($fh, $filename) = tempfile( DIR => $self->workdir );
        print $fh $res->content;
        close $fh;
        $playerfile = $filename;
    }
    {
        my (undef, $filename) = tempfile( DIR => $self->workdir );
        system($self->swfextract, "-b", 14, $playerfile, "-o", $filename);
        $authfile = $filename;
    }
    return $authfile;
}

sub partialkey {
    my $self = shift;
    my $auth1_fms = $self->auth1_fms;
    my $buffer = '';
    open my $fh, '<', $self->authkey_file;
    binmode($fh);
    seek($fh, $auth1_fms->{offset}, 1);
    read($fh, $buffer, $auth1_fms->{length});
    close $fh;
    return encode_base64($buffer);
}

sub _request {
    my $self = shift;
    my $url  = shift;
    my $header = shift  || [];
    my $content = shift || {};

    $url = sprintf '/%s', $url if $url !~ /^\//;
    $furl->post(
        sprintf('%s%s', $self->api, $url),
        [
            "X-Radiko-App" => 'pc_1',
            "X-Radiko-App-Version" => '2.0.1',
            "X-Radiko-User" => 'test-stream',
            "X-Radiko-Device" => 'pc',
            @$header
        ],
        $content
    );
}

sub _build_auth1_fms {
    my $self = shift;

    my $res = $self->_request('auth1_fms');
    die "auth1_fms fail! " . $res->content if !$res->is_success;
    return {
        authtoken => $res->header('x-radiko-authtoken'),
        offset    => $res->header('x-radiko-keyoffset'),
        length    => $res->header('x-radiko-keylength')
    };
}

sub _build_auth2_fms {
    my $self = shift;

    my $auth1_fms = $self->auth1_fms;
    my $res = $self->_request('auth2_fms', [
        "pragma" => "no-cache",
         "X-Radiko-Authtoken"  => $auth1_fms->{authtoken},
         "X-Radiko-Partialkey" => $self->partialkey,
    ]);
    die "auth2_fms fail! " . $res->content if !$res->is_success;
    (my $content = $res->decoded_content) =~ s/\r?\n//g;
    my ($areaid, $name_ja, $name_en) = split ",", $content;
    die "response invalid! " . $res->content if !$areaid || !$name_ja || !$name_en;
    return {
        areaid  => $areaid,
        name_ja => $name_ja,
        name_en => $name_en
    };
}

sub _build_stream_url {
    my $self = shift;

    my $channel = $self->channel;
    (my $url_base = $self->url) =~ s{^https}{http};
    my $url = $url_base . sprintf '/station/stream/%s.xml', $channel;
    my $res = $furl->get($url);
    die "can't find channel: $url" if !$res->is_success;
    my $content = $res->content;
    if (my @match = $content =~ /<item>(.*):\/\/(.+?)\/(.+)\/(.+?)<\/item>/) {
        return {
            rtmp => sprintf('%s://%s', $match[0], $match[1]),
            app  => $match[2],
            playpath => $match[3]
        };
    }
    die "can't resolve rtmp:\n$content";
}

sub _rtmpdump_args {
    my ($self, $filename) = @_;

    my %rtmpdump_opt = %{ $self->rtmpdump_opt };

    my $stream_url = $self->stream_url;
    my @r_opts;
    push @r_opts, sprintf('--%s', $_), $stream_url->{$_} for qw/rtmp playpath app/;
    push @r_opts, sprintf('--%s', $_), $rtmpdump_opt{$_} for keys %rtmpdump_opt;
    push @r_opts, '--flv', $filename;
    push @r_opts, '-C', 'S:""' for (1 ..3);
    push @r_opts, '-C', sprintf('S:%s', $self->auth1_fms->{authtoken});
    push @r_opts, '-W', $self->swf;    
    push @r_opts, '--live';

    return @r_opts;
}

sub _ffmpeg_args {
    my ($self, $filename) = @_;

    my %ffmpeg_opt = %{ $self->ffmpeg_opt };
    $ffmpeg_opt{i}      ||= $filename;
    $ffmpeg_opt{acodec} ||= 'copy';

    my $output = delete $ffmpeg_opt{_output};
    my @f_opts = ('-i', delete($ffmpeg_opt{i}));
    push @f_opts, sprintf('-%s', $_), $ffmpeg_opt{$_} for keys %ffmpeg_opt;
    push @f_opts, $output;
    return @f_opts;
}

sub record {
    my $self = shift;
    my $args = shift || {};
    $args->{minutes} ||= 1;
    $args->{output}  ||= $self->workdir . '/foo.mp4';

    $self->auth2_fms;

    $self->rtmpdump_opt->{stop}  ||= $args->{minutes} * 60;
    $self->ffmpeg_opt->{_output} ||= $args->{output};

    my (undef, $flv) = tempfile( DIR => $self->workdir, SUFFIX => '.flv' );

    system($self->rtmpdump, $self->_rtmpdump_args($flv)); # long long time
    system($self->ffmpeg,   $self->_ffmpeg_args($flv));
}

1;
__END__

=encoding utf-8

=head1 NAME

Radiko - radiko recorder

=head1 SYNOPSIS

    use Radiko;

    my $radiko = Radiko->new(
        channel => 'INT', # see http://www.dcc-jpl.com/foltia/wiki/radikomemo
    );

    $radiko->record({ minutes => 60, output => '/tmp/foo.mp4' }); # recording start


=head1 DESCRIPTION

Radiko is ...

=head1 LICENSE

Copyright (C) taiyoh.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

taiyoh E<lt>sun.basix@gmail.comE<gt>

=cut

