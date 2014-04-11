#!perl
#-------------------------------------------------------------------------------
# Copyright (c) 2001-2003, Steve Hay. All rights reserved.
#
# Module Name:  Win32::SharedFileOpen
# Source File:  06_fsopen_access.t
# Description:  Test program to check fsopen() access modes
#-------------------------------------------------------------------------------

use 5.006;

use strict;
use warnings;

use Errno;
use Test;
use Win32::WinError;

BEGIN {
    plan tests => 34;                   # Number of tests to be executed
};

use Win32::SharedFileOpen qw(:DEFAULT new_fh);

#-------------------------------------------------------------------------------
#
# Main program.
#

MAIN: {
    my( $file,                          # Test file
        $str,                           # Test string to read/write
        $strlen,                        # Test string length
        $fh,                            # Test filehandle
        $ret,                           # Return value from fsopen()
        $line                           # Line read from file
        );

                                        # Test 1: Did we make it this far OK?
    ok(1);

    $file   = 'test.txt';
    $str    = 'Hello, world.';
    $strlen = length $str;

    unlink $file or die "Can't delete file '$file': $!\n" if -e $file;

                                        # Tests 2-10: Check 'r'/'w'
    $fh = new_fh();
    $ret = fsopen($fh, $file, 'r', SH_DENYNO);
    ok(not defined $ret and $!{ENOENT} and $^E == ERROR_FILE_NOT_FOUND);

    $fh = new_fh();
    $ret = fsopen($fh, $file, 'w', SH_DENYNO);
    ok($ret);

    ok(print $fh "$str\n");

    seek $fh, 0, 0;
    {
        no warnings 'io';
        ok(not defined <$fh>);
    }

    close $fh;
    ok(-s $file == $strlen + 2);

    $fh = new_fh();
    $ret = fsopen($fh, $file, 'r', SH_DENYNO);
    ok($ret);

    {
        no warnings 'io';
        ok(not print $fh "$str\n");
    }

    seek $fh, 0, 0;
    chomp($line = <$fh>);
    ok($line eq $str);

    close $fh;
    ok(-s $file == $strlen + 2);

                                        # Tests 11-14: Check 'a'
    $fh = new_fh();
    $ret = fsopen($fh, $file, 'a', SH_DENYNO);
    ok($ret);

    ok(print $fh "$str\n");

    seek $fh, 0, 0;
    {
        no warnings 'io';
        ok(not defined <$fh>);
    }

    close $fh;
    ok(-s $file == ($strlen + 2) * 2);

    unlink $file;

                                        # Tests 15-23: Check 'r+'/'w+'
    $fh = new_fh();
    $ret = fsopen($fh, $file, 'r+', SH_DENYNO);
    ok(not defined $ret and $!{ENOENT} and $^E == ERROR_FILE_NOT_FOUND);

    $fh = new_fh();
    $ret = fsopen($fh, $file, 'w+', SH_DENYNO);
    ok($ret);

    ok(print $fh "$str\n");

    seek $fh, 0, 0;
    chomp($line = <$fh>);
    ok($line eq $str);

    close $fh;
    ok(-s $file == $strlen + 2);

    $fh = new_fh();
    $ret = fsopen($fh, $file, 'r+', SH_DENYNO);
    ok($ret);

    ok(print $fh "$str\n");

    seek $fh, 0, 0;
    chomp($line = <$fh>);
    ok($line eq $str);

    close $fh;
    ok(-s $file == $strlen + 2);

                                        # Tests 24-27: Check 'a+'
    $fh = new_fh();
    $ret = fsopen($fh, $file, 'a+', SH_DENYNO);
    ok($ret);

    ok(print $fh "$str\n");

    seek $fh, 0, 0;
    chomp($line = <$fh>);
    ok($line eq $str);

    close $fh;
    ok(-s $file == ($strlen + 2) * 2);

    unlink $file;

                                        # Tests 28-31: Check 't'/'b'
    $fh = new_fh();
    fsopen($fh, $file, 'wt', SH_DENYNO);
    print $fh "$str\n";
    close $fh;
    ok(-s $file == $strlen + 2);

    $fh = new_fh();
    fsopen($fh, $file, 'wt', SH_DENYNO);
    binmode $fh, ':raw';
    print $fh "$str\n";
    close $fh;
    ok(-s $file == $strlen + 1);

    $fh = new_fh();
    fsopen($fh, $file, 'wb', SH_DENYNO);
    print $fh "$str\n";
    close $fh;
    ok(-s $file == $strlen + 1);

    $fh = new_fh();
    fsopen($fh, $file, 'wb', SH_DENYNO);
    binmode $fh, ':crlf';
    print $fh "$str\n";
    close $fh;
    ok(-s $file == $strlen + 2);

    unlink $file;

                                        # Tests 32-34: Check permissions
    $fh = new_fh();
    $ret = fsopen($fh, '.', 'r', SH_DENYNO);
    ok(not defined $ret and $!{EACCES} and $^E == ERROR_ACCESS_DENIED);

    $fh = new_fh();
    fsopen($fh, $file, 'w', SH_DENYNO);
    print $fh "$str\n";
    close $fh;
    chmod 0444, $file;

    $fh = new_fh();
    $ret = fsopen($fh, $file, 'r', SH_DENYNO);
    ok($ret);
    close $fh;

    $fh = new_fh();
    $ret = fsopen($fh, $file, 'w', SH_DENYNO);
    ok(not defined $ret and $!{EACCES} and $^E == ERROR_ACCESS_DENIED);

    unlink $file;
}

#-------------------------------------------------------------------------------
