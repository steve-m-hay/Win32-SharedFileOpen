#-------------------------------------------------------------------------------
# Copyright (c)	2001-2003, Steve Hay. All rights reserved.
#
# Module Name:	Win32::SharedFileOpen
# Source File:	SharedFileOpen.pm
# Description:	Main Perl module
#-------------------------------------------------------------------------------

package Win32::SharedFileOpen;

use 5.006;

use strict;
use warnings;

use Carp;
use Exporter qw();
use Symbol;
use Win32;
use Win32::WinError qw(
	ERROR_ACCESS_DENIED
	ERROR_SHARING_VIOLATION
	ERROR_FILE_EXISTS
	ERROR_ENVVAR_NOT_FOUND
	ERROR_TOO_MANY_OPEN_FILES
	ERROR_FILE_NOT_FOUND
);
use XSLoader qw();

sub fsopen(*$$$);
sub sopen(*$$$;$);
sub new_fh();

BEGIN {
	# Get the ERROR_SHARING_VIOLATION constant loaded now otherwise loading it
	# later the first time that we test for an error can actually interfere with
	# the value of $! (which we might also want to test) because the constant is
	# autoloaded by Win32::WinError and the AUTOLOAD() subroutine in that module
	# resets $! in the versions included in libwin32-0.18 and earlier.
	# Likewise preload some other ERROR_* constants that our use()'rs might need
	# otherwise loading them later can similarly interfere with the value of $
	# in libwin32-0.191 and earlier with debug builds of Perl.
	ERROR_ACCESS_DENIED;
	ERROR_SHARING_VIOLATION;
	ERROR_FILE_EXISTS;
	ERROR_ENVVAR_NOT_FOUND;
	ERROR_TOO_MANY_OPEN_FILES;
	ERROR_FILE_NOT_FOUND;
}

our @ISA = qw(Exporter);

our @EXPORT = qw(
	fsopen
	sopen
);

our @EXPORT_OK = qw(
	gensym
	new_fh
);

our %EXPORT_TAGS = (
	oflags => [ qw(
		O_APPEND
		O_BINARY
		O_CREAT
		O_EXCL
		O_NOINHERIT
		O_RANDOM
		O_RAW
		O_RDONLY
		O_RDWR
		O_SEQUENTIAL
		O_SHORT_LIVED
		O_TEMPORARY
		O_TEXT
		O_TRUNC
		O_WRONLY
	) ],

	pmodes => [ qw(
		S_IREAD
		S_IWRITE
	) ],

	shflags => [ qw(
		SH_DENYNO
		SH_DENYRD
		SH_DENYRW
		SH_DENYWR
	) ],

	retry => [ qw(
		INFINITE
		$Max_Time
		$Max_Tries
		$Retry_Timeout
	) ]
);

Exporter::export_tags(qw(oflags pmodes shflags));

Exporter::export_ok_tags(qw(retry));

our $VERSION = '3.14';

# Debug setting. (0 = No debug, 1 = summary of what fsopen() or sopen() did, 2 =
# additional information revealing exactly what failed.)
tie our $Debug, __PACKAGE__ . '::_NaturalNumber', 0, '$Debug';

# Maximum time to try and retry opening a file. (Retries are only attempted if
# the previous try failed due to a sharing violation.)
tie our $Max_Time, __PACKAGE__ . '::_NaturalNumber', undef, '$Max_Time';

# Maximum number of times to try opening a file. (Retries are only attempted if
# the previous try failed due to a sharing violation.)
tie our $Max_Tries, __PACKAGE__ . '::_NaturalNumber', undef, '$Max_Tries';

# Time to wait between tries at opening a file. (Milliseconds.)
tie our $Retry_Timeout, __PACKAGE__ . '::_NaturalNumber', 250, '$Retry_Timeout';

# Autoload the O_*, S_* and SH_* flags from the constant() XS fuction.
sub AUTOLOAD {
	my(	$constant,						# Name of constant being autoloaded
		$error,							# Error from constant autoload, if any
		$value							# Value of constant being autoloaded
		);

	our($AUTOLOAD						# Fully-qualified name of method invoked
		);

	# Get the name of the constant to generate a subroutine for.
	($constant = $AUTOLOAD) =~ s/^.*:://;

	# Avoid deep recursion on AUTOLOAD() if constant() is not defined.
	croak('Unexpected error in AUTOLOAD(): constant() is not defined')
		if $constant eq 'constant';

	($error, $value) = constant($constant);

	# Handle any error from looking up the constant.
	croak($error) if $error;

	# Generate an in-line subroutine returning the required value.
	{
		no strict 'refs';
		*$AUTOLOAD = sub { return $value };
	}

	# Switch to the subroutine that we have just generated.
	goto &$AUTOLOAD;
}

XSLoader::load('Win32::SharedFileOpen', $VERSION);

#-------------------------------------------------------------------------------
#
# Public subroutines.
#

sub fsopen(*$$$) {
	my(	$fh,							# "Filehandle" to be opened
		$file,							# File to open
		$mode,							# Mode string specifying access mode
		$shflag							# SH_* flag specifying sharing mode
		) = @_;

	my(	$start,							# Time started trying to open file
		$tries,							# Number of tries at opening file
		$success						# Return value from _fsopen()
		);

	croak("fsopen() can't use the undefined value as an indirect filehandle")
		unless defined $fh;

	# Make sure the "filehandle" argument supplied is fit for purpose.
	$fh = qualify_to_ref($fh, caller);

	for ($start = time, $tries = 0; ; Win32::Sleep($Retry_Timeout)) {
		$success = _fsopen($fh, $file, $mode, $shflag);

		$tries++;

		last if $success
			 or $ != ERROR_SHARING_VIOLATION
			 or (not defined $Max_Time and not defined $Max_Tries)
			 or (defined $Max_Time and $Max_Time != 0 and
				 $Max_Time != INFINITE() and time - $start >= $Max_Time)
			 or (defined $Max_Tries and $Max_Tries != 0 and
				 $Max_Tries != INFINITE() and $tries >= $Max_Tries);
	}

	if ($Debug) {
		my $time = time - $start;

		printf STDERR
			"_fsopen() on '$file' %s in $time %s after $tries %s: %s.\n",
			($success ? 'succeeded' : 'failed'),
			($time == 1 ? 'second' : 'seconds'),
			($tries == 1 ? 'try' : 'tries'),
			($success ? 'using file descriptor ' . fileno($fh) : $);
	}

	if ($success) {
		# The _fsopen() XS function always opens the filehandle in "binary"
		# mode, so push a "text" mode layer on top unless "binary" mode is what
		# was actually asked for. (See comments in XS file for the reason why.)
		unless ($mode =~ /b/io) {
			unless (binmode $fh, ':crlf') {
				if ($Debug > 1) {
					print STDERR "Could not push text mode layer on PerlIO " .
								 "stream for file '$file'\n";
				}
			}
		}

		return 1;
	}
	else {
		return;
	}
}

sub sopen(*$$$;$) {
	my(	$fh,							# "Filehandle" to be opened
		$file,							# File to open
		$oflag,							# O_* flag specifying access mode
		$shflag,						# SH_* flag specifying sharing mode
		$pmode							# S_* flag specifying file permissions
		) = @_;

	my(	$start,							# Time started trying to open file
		$tries,							# Number of tries at opening file
		$success						# Return value from _sopen()
		);

	croak("sopen() can't use the undefined value as an indirect filehandle")
		unless defined $fh;

	# Make sure the "filehandle" argument supplied is fit for purpose.
	$fh = qualify_to_ref($fh, caller);

	for ($start = time, $tries = 0; ; Win32::Sleep($Retry_Timeout)) {
		if (@_ > 4) {
			$success = _sopen($fh, $file, $oflag, $shflag, $pmode);
		}
		else {
			$success = _sopen($fh, $file, $oflag, $shflag);
		}

		$tries++;

		last if $success
			 or $ != ERROR_SHARING_VIOLATION
			 or (not defined $Max_Time and not defined $Max_Tries)
			 or (defined $Max_Time and $Max_Time != 0 and
				 $Max_Time != INFINITE() and time - $start >= $Max_Time)
			 or (defined $Max_Tries and $Max_Tries != 0 and
				 $Max_Tries != INFINITE() and $tries >= $Max_Tries);
	}

	if ($Debug) {
		my $time = time - $start;

		printf STDERR
			"_sopen() on '$file' %s in $time %s after $tries %s: %s.\n",
			($success ? 'succeeded' : 'failed'),
			($time == 1 ? 'second' : 'seconds'),
			($tries == 1 ? 'try' : 'tries'),
			($success ? 'using file descriptor ' . fileno($fh) : $);
	}

	if ($success) {
		# The _sopen() XS function always opens the filehandle in "binary"
		# mode, so push a "text" mode layer on top unless "binary" mode is what
		# was actually asked for. (See comments in XS file for the reason why.)
		unless ($oflag & O_BINARY()) {
			unless (binmode $fh, ':crlf') {
				if ($Debug > 1) {
					print STDERR "Could not push text mode layer on PerlIO " .
								 "stream for file '$file'\n";
				}
			}
		}

		return 1;
	}
	else {
		return;
	}
}

sub new_fh() {
	no warnings 'once';
	return local *FH;
}

#-------------------------------------------------------------------------------
#
# Private class to restrict the values of $Debug, $Max_Time, $Max_Tries and
# $Retry_Timeout to the set of natural numbers (i.e. the set of non-negative
# integers).
#

package Win32::SharedFileOpen::_NaturalNumber;

use Carp;

sub TIESCALAR {
	my(	$class,							# Invocant class
		$value,							# Initial value
		$name							# Name of tied scalar
		) = @_;

	my(	$self							# New object
		);

	croak("Usage: tie SCALAR, '$class', SCALARVALUE, SCALARNAME")
		unless @_ == 3;

	$self = bless { _name => $name, _value => undef }, $class;

	# Use our own STORE() method to store the value to make sure it is valid.
	$self->STORE($value);

	return $self;
}

sub FETCH {
	my(	$self							# Invocant object
		) = @_;

	return $self->{_value};
}

sub STORE {
	my(	$self,							# Invocant object
		$value							# New value to store
		) = @_;

	if (not defined $value) {
		$self->{_value} = undef;
	}
	elsif ($value eq '' or $value =~ /\D/) {
		croak("Invalid value for '$self->{_name}': '$value' is not a natural " .
			  "number");
	}
	else {
		$self->{_value} = 0 + $value;
	}

	return $self->{_value};
}

1;

__END__

#-------------------------------------------------------------------------------
#
# Documentation.
#

=head1 NAME

Win32::SharedFileOpen - Open a file for shared reading and/or writing

=head1 SYNOPSIS

	# Read and write files a la open(), but with mandatory file locking:
	# ------------------------------------------------------------------

	use Win32::SharedFileOpen;

	fsopen(FH1, 'readme', 'r', SH_DENYWR) or
		die "Can't read 'readme' and take write-lock: $^E\n";

	fsopen(FH2, 'writeme', 'w', SH_DENYRW) or
		die "Can't write 'writeme' and take read/write-lock: $^E\n";

	# Read and write files a la sysopen(), but with mandatory file locking:
	# ---------------------------------------------------------------------

	use Win32::SharedFileOpen;

	sopen(FH1, 'readme', O_RDONLY, SH_DENYWR) or
		die "Can't read 'readme' and take write-lock: $^E\n";

	sopen(FH2, 'writeme', O_WRONLY | O_CREAT | O_TRUNC, SH_DENYRW, S_IWRITE) or
		die "Can't write 'writeme' and take read/write-lock: $^E\n";

	# Retry opening the file if it fails due to a sharing violation:
	# --------------------------------------------------------------

	use Win32::SharedFileOpen qw(:DEFAULT :retry);

	$Max_Time      = 10;	# Try opening the file for up to 10 seconds
	$Retry_Timeout = 500;	# Wait 500 milliseconds between each try

	fsopen(FH, 'readme', 'r', SH_DENYNO) or
		die "Can't read 'readme' after retrying for $Max_Time seconds: $^E\n";

	# Use a lexical indirect filehandle that closes itself when destroyed:
	# --------------------------------------------------------------------

	use Win32::SharedFileOpen qw(:DEFAULT new_fh);

	{
		my $fh = new_fh();

		fsopen($fh, 'readme', 'r', SH_DENYNO) or
			die "Can't read 'readme': $^E\n";

		while (<$fh>) {
			# ... Do some stuff ...
		}

	}	# ... $fh is automatically closed here

=head1 DESCRIPTION

This module provides a Perl interface to the Microsoft C library functions
C<_fsopen()> and C<_sopen()>. These functions are counterparts to the standard C
library functions C<fopen(3)> and C<open(2)> respectively (which are already
effectively available in Perl as C<open()> and C<sysopen()> respectively), but
are intended for use when opening a file for subsequent shared reading and/or
writing.

The C<_fsopen()> function, like C<fopen(3)>, takes a file and a "mode string"
(e.g. C<'r'> and C<'w'>) as arguments and opens the file as a stream, returning
a pointer to a C<FILE> structure, while C<_sopen()>, like C<open(2)>, takes an
"oflag" (e.g. C<O_RDONLY> and C<O_WRONLY>) instead of the "mode string" and
returns an C<int> file descriptor (which the Microsoft documentation confusingly
refers to as a C run-time "file handle", not to be confused here with a Perl
"filehandle" (or indeed with the operating-system "file handle" returned by the
Win32 API function C<CreateFile()>!)). The C<_sopen()> and C<open(2)> functions
also take another, optional, "pmode" argument (e.g. C<S_IREAD> and C<S_IWRITE>)
specifying the permission settings of the file if it has just been created.

The difference between the Microsoft-specific functions and their standard
counterparts is that the Microsoft-specific functions also take an extra
"shflag" argument (e.g. C<SH_DENYRD> and C<SH_DENYWR>) which specifies how to
prepare the file for subsequent shared reading and/or writing. This flag can be
used to specify that either, both or neither of read access and write access
will be denied to other processes sharing the file.

This share access control is thus effectively a form a file-locking which,
unlike C<flock(3)> and C<lockf(3)> and their corresponding Perl function
C<flock()>, is I<mandatory> rather than just I<advisory>. This means that if,
for example, you "deny read access" for the file that you have opened then no
other process will be able to read that file while you still have it open,
whether or not they are playing the same ball game as you. They cannot gain read
access to it by simply not honouring the same file opening/locking scheme as
you.

This module provides straightforward Perl "wrapper" functions, C<fsopen()> and
C<sopen()>, for both of these Microsoft C library functions (with the leading
"_" character removed from their names). These Perl functions maintain the same
formal parameters as the original C functions, except for the addition of an
initial filehandle parameter like the Perl built-in functions C<open()> and
C<sysopen()> have. This is used to make the Perl filehandle opened available to
the caller (rather than using the functions' return values, which are now simple
Booleans to indicate success or failure).

The value passed to the functions in this first parameter can be a
straight-forward filehandle (C<FH>) or any of the following:

=over 4

=item *

a typeglob (either a named typeglob like C<*FH>, or an anonymous typeglob (e.g.
from C<gensym()> or C<new_fh()> in this module) in a scalar variable);

=item *

a reference to a typeglob (either a hard reference like C<\*FH>, or a name like
C<'FH'> to be used as a symbolic reference to a typeglob in the caller's
package);

=item *

a suitable IO object (e.g. an instance of IO::Handle, IO::File or FileHandle).

=back

These functions, however, do not have the ability of C<open()> and C<sysopen()>
to auto-vivify the undefined scalar value into something that can be used as a
filehandle, so calls like "C<fsopen(my $fh, ...)>" will C<croak()> with a
message to this effect.

The "oflags" and "shflags", as well as the "pmode" flags used by C<_sopen()>,
are all made available to Perl by this module, and are all exported by default.
Clearly this module will only build using Microsoft Visual C, so only the flags
known to that system [as of version 6.0] are exported, rather than re-exporting
all of the C<O_*> and C<S_I*> flags from the Fcntl module like, for example,
IO::File does. In any case, Fcntl does not know about the Microsoft-specific
C<_O_SHORT_LIVED> and C<SH_*> flags. (The C<_O_SHORT_LIVED> flag is exported
(like the C<_fsopen()> and C<_sopen()> functions themselves) I<without> the
leading "_" character.)

Both functions can be made to automatically retry opening a file (indefinitely,
or up to a specified maximum time or number of times, and at a specified
frequency) if the file could not be opened due to a sharing violation, via the
L<"Variables"> I<$Max_Time>, I<$Max_Tries> and I<$Retry_Timeout> and the
C<INFINITE> flag.

=head2 Functions

=over 4

=item C<fsopen($fh, $file, $mode, $shflag)>

Opens the file I<$file> using the L<filehandle|"Filehandles"> (or
L<indirect filehandle|"Indirect Filehandles">) I<$fh> in the access mode
specified by L<I<$mode>|"Mode Strings"> and prepares the file for subsequent
shared reading and/or writing as specified by L<I<$shflag>|"SH_* Flags">.

Returns a non-zero value if the file was successfully opened, or returns
C<undef> and sets C<$!> and/or C<$^E> if the file could not be opened.

=item C<sopen($fh, $file, $oflag, $shflag[, $pmode])>

Opens the file I<$file> using the L<filehandle|"Filehandles"> (or
L<indirect filehandle|"Indirect Filehandles">) I<$fh> in the access mode
specified by L<I<$oflag>|"O_* Flags"> and prepares the file for subsequent
shared reading and/or writing as specified by L<I<$shflag>|"SH_* Flags">. The
optional L<I<$pmode>|"S_I* Flags"> argument specifies the file's permission
settings if the file has just been created; it is required if (and only if) the
access mode includes C<O_CREAT>.

Returns a non-zero value if the file was successfully opened, or returns
C<undef> and sets C<$!> and/or C<$^E> if the file could not be opened.

=item C<gensym()>

Returns a new, anonymous, typeglob which can be used as an
L<indirect filehandle|"Indirect Filehandles"> in the first parameter of
C<fsopen()> and C<sopen()>.

This function is not actually implemented by this module itself: it is simply
imported from the L<Symbol|Symbol> module and then re-exported. See
L<"Indirect Filehandles"> for more details.

=item C<new_fh()>

Returns a new, anonymous, typeglob which can be used as an
L<indirect filehandle|"Indirect Filehandles"> in the first parameter of
C<fsopen()> and C<sopen()>.

This function is an implementation of the "First-Class Filehandle Trick". See
L<"The First-Class Filehandle Trick"> for more details.

=back

=head2 Mode Strings

The I<$mode> argument in C<fsopen()> specifies the type of access requested for
the file, as follows:

=over 4

=item C<'r'>

Opens the file for reading only. Fails if the file does not already exist.

=item C<'w'>

Opens the file for writing only. Creates the file if it does not already exist;
destroys the contents of the file if it does already exist.

=item C<'a'>

Opens the file for appending only. Creates the file if it does not already
exist.

=item C<'r+'>

Opens the file for both reading and writing. Fails if the file does not already
exist.

=item C<'w+'>

Opens the file for both reading and writing. Creates the file if it does not
already exist; destroys the contents of the file if it does already exist.

=item C<'a+'>

Opens the file for both reading and appending. Creates the file if it does not
already exist.

=back

When the file is opened for appending the file pointer is always forced to the
end of the file before any write operation is performed.

The following table shows the equivalent combination of L<"O_* Flags"> for each
mode string:

	+------+-------------------------------+
	| 'r'  | O_RDONLY                      |
	+------+-------------------------------+
	| 'w'  | O_WRONLY | O_CREAT | O_TRUNC  |
	+------+-------------------------------+
	| 'a'  | O_WRONLY | O_CREAT | O_APPEND |
	+------+-------------------------------+
	| 'r+' | O_RDWR                        |
	+------+-------------------------------+
	| 'w+' | O_RDWR | O_CREAT | O_TRUNC    |
	+------+-------------------------------+
	| 'a+' | O_RDWR | O_CREAT | O_APPEND   |
	+------+-------------------------------+

See also L<"Text and Binary Modes">.

=head2 O_* Flags

The I<$oflag> argument in C<sopen()> specifies the type of access requested for
the file, as follows:

=over 4

=item C<O_RDONLY>

Opens the file for reading only.

=item C<O_WRONLY>

Opens the file for writing only.

=item C<O_RDWR>

Opens the file for both reading and writing.

=back

Exactly one of the above flags must be used to specify the file access mode:
there is no default value. In addition, the following flags may also be used in
bitwise-OR combination:

=over 4

=item C<O_APPEND>

The file pointer is always forced to the end of the file before any write
operation is performed.

=item C<O_CREAT>

Creates the file if it does not already exist. (Has no effect if the file does
already exist.) The L<I<$pmode>|"S_I* Flags"> argument is required if (and only
if) this flag is used.

=item C<O_EXCL>

Fails if the file already exists. Only applies when used with C<O_CREAT>.

=item C<O_NOINHERIT>

Prevents creation of a shared file descriptor.

=item C<O_RANDOM>

Specifies the disk access will be primarily random.

=item C<O_SEQUENTIAL>

Specifies the disk access will be primarily sequential.

=item C<O_SHORT_LIVED>

Used with C<O_CREAT>, creates the file such that, if possible, it does not flush
the file to disk.

=item C<O_TEMPORARY>

Used with C<O_CREAT>, creates the file as temporary. The file will be deleted
when the last file descriptor attached to it is closed.

=item C<O_TRUNC>

Truncates the file to zero length, destroying the contents of the file, if it
already exists. Cannot be specified with C<O_RDONLY>, and the file must have
write permission.

=back

See also L<"Text and Binary Modes">.

=head2 Text and Binary Modes

Both C<fsopen()> and C<sopen()> calls can specify whether the file should be
opened in text (translated) mode or binary (untranslated) mode.

If the file is opened in text mode then on input carriage return-linefeed
(CR-LF) pairs are translated to single linefeed (LF) characters and Ctrl+Z is
interpreted as end-of-file (EOF), while on output linefeed (LF) characters are
translated to carriage return-linefeed (CR-LF) pairs.

These translations are not performed if the file is opened in binary mode.

If neither mode is specified then text mode is assumed by default, as is usual
for Perl filehandles. Binary mode can still be enabled after the file has been
opened (but only before any I/O has been performed on it) by calling
C<binmode()> in the usual way.

=over 4

=item C<'t'>

=item C<'b'>

Text/binary modes are specified for C<fsopen()> by inserting a C<'t'> or a
C<'b'> respectively into the L<I<$mode>|"Mode Strings"> string, immediately
following the C<'r'>, C<'w'> or C<'a'>, for example:

	my $fh = fsopen($file, 'wt', SH_DENYNO);

=item C<O_TEXT>

=item C<O_BINARY>

=item C<O_RAW>

Text/binary modes are specified for C<sopen()> by using C<O_TEXT> or C<O_BINARY>
(or C<O_RAW>, which is an alias for C<O_BINARY>) respectively in bitwise-OR
combination with other C<O_*> flags in the L<I<$oflag>|"O_* Flags"> argument,
for example:

	my $fh = sopen($file, O_WRONLY | O_CREAT | O_TRUNC | O_TEXT, SH_DENYNO,
				S_IWRITE);

=back

=head2 SH_* Flags

The I<$shflag> argument in both C<fsopen()> and C<sopen()> specifies the type of
sharing access permitted for the file, as follows:

=over 4

=item C<SH_DENYNO>

Permits both read and write access to the file.

=item C<SH_DENYRD>

Denies read access to the file; write access is permitted.

=item C<SH_DENYWR>

Denies write access to the file; read access is permitted.

=item C<SH_DENYRW>

Denies both read and write access to the file.

=back

=head2 S_I* Flags

The I<$pmode> argument in C<sopen()> is required if (and only if) the access
mode, I<$oflag>, includes C<O_CREAT>. If the file does not already exist then
I<$pmode> specifies the file's permission settings, which are set the first time
the file is closed. (It has no effect if the file already exists.) The value is
specified as follows:

=over 4

=item C<S_IREAD>

Permits reading.

=item C<S_IWRITE>

Permits writing.

=back

Note that it is evidently not possible to deny read permission, so C<S_IWRITE>
and C<S_IREAD | S_IWRITE> are equivalent.

=head2 Other Flags

=over 4

=item C<INFINITE>

This flag can be assigned to I<$Max_Time> and/or I<$Max_Tries> (see below) in
order to have C<fsopen()> or C<sopen()> indefinitely retry opening a file until
it is either opened successfully or it cannot be opened for some reason other
than a sharing violation.

=back

=head2 Variables

=over 4

=item I<$Debug>

Debug mode setting.

The value must be a natural number (i.e. a non-negative integer); an exception
is raised on any attempt to specify an invalid value.

Setting this variable to a value greater than 0 will cause debug information to
be emitted (via a straight-forward C<print()> on STDERR). How much output is
produced depends on the actual value: currently, the value 1 will produce a
summary of what C<fsopen()> or C<sopen()> did just before it returns, while a
value greater than 1 will provide additional information in the event of a
failure revealing exactly what failed.

The default value is 0, i.e. debug mode is "off".

=item I<$Max_Time>

=item I<$Max_Tries>

These variables specify respectively the maximum time for which to try, and the
maximum number of times to try, opening a file on a single call to C<fsopen()>
or C<sopen()> while the file cannot be opened due to a sharing violation
(specifically, while "C<$^E == ERROR_SHARING_VIOLATION>").

The I<$Max_Time> variable is generally more useful than I<$Max_Tries> because
even with a common value of I<$Retry_Timeout> (see below) two processes may
retry opening a shared file at significantly different rates. For example, if
I<$Retry_Timeout> is 0 then a process which can access the file in question on a
local disk may retry thousands of times per second, while a process on another
machine trying to open the same file across a network connection may only retry
once or twice per second. Clearly, specifying the maximum time that a process is
prepared to wait is preferable to specifying the maximum number of times to try.

For this reason, if both variables are specified then only I<$Max_Time> is used;
I<$Max_Tries> is ignored in that case. Use the undefined value to explicitly
have one or the other variable ignored. No retries are attempted if both
variables are undefined. 

Otherwise, the values must be natural numbers (i.e. non-negative integers); an
exception is raised on any attempt to specify an invalid value.

The C<INFINITE> flag (see above) indicates that the retries should be continued
I<ad infinitum> if necessary. The value zero has the same meaning for backwards
compatibility with previous versions of this module.

The default values are both C<undef>, i.e. no retries are attempted.

=item I<$Retry_Timeout>

Specifies the time to wait (in milliseconds) between tries at opening a file
(see I<$Max_Time> and I<$Max_Tries> above).

The value must be a natural number (i.e. a non-negative integer); an exception
is raised on any attempt to specify an invalid value.

The default value is 250, i.e. wait for one quarter of a second between tries.

=back

=head1 DIAGNOSTICS

=head2 Warnings and Error Messages

The following diagnostic messages may be produced by this module. They are
classified as follows (a la L<perldiag>):

	(W) A warning (optional).
	(F) A fatal error (trappable).
	(I) An internal error that you should never see (trappable).

=over 4

=item %s() can't use the undefined value as an indirect filehandle

(F) The specified function was passed the undefined value as the first argument.
That is not a filehandle, cannot be used as an indirect filehandle, and
(unlike the Perl built-in functions C<open()> and C<sysopen()>) the function is
unable to auto-vivify something that can be used as an indirect filehandle in
such a case.

=item Invalid value for '%s': '%s' is not a natural number

(F) An attempt was made to set the specified variable to something other than a
natural number (i.e. a non-negative integer). This is not allowed.

=item Unexpected error in AUTOLOAD(): constant() is not defined

(I) There was an unexpected error looking up the value of the specified
constant: the constant-lookup function itself is apparently not defined.

=item Unknown IoTYPE '%s'

(I) The PerlIO stream associated with the C file stream opened by one of the
Microsoft C library functions C<_fsopen()> or C<_sopen()> is of an unknown type.

=item Unknown mode '%s'

(I) The PerlIO stream associated with the C file stream opened by one of the
Microsoft C library functions C<_fsopen()> or C<_sopen()> is in an unknown mode.

=item Usage: tie SCALAR, '%s', SCALARVALUE, SCALARNAME

(I) The class used internally to C<tie()> the I<$Debug>, I<$Max_Time>,
I<$Max_Tries> and I<$Retry_Timeout> variables to has been used incorrectly.

=back

=head2 Error Values

Both C<fsopen()> and C<sopen()> set the Perl Special Variables C<$!> and/or
C<$^E> to values indicating the cause of the error when they fail. The possible
values of each are as follows (C<$!> shown first, C<$^E> underneath):

=over 4

=item EACCES (Permission denied) [1]

=item ERROR_ACCESS_DENIED (Access is denied)

The I<$file> is a directory, or is a read-only file and an attempt was made to
open it for writing.

=item EACCES (Permission denied) [2]

=item ERROR_SHARING_VIOLATION (The process cannot access the file because it is
being used by another process.)

The I<$file> cannot be opened because another process already has it open and is
denying the requested access mode.

This is, of course, the error that other processes will get when trying to open
a file in a certain access mode when we have already opened the same file with a
sharing mode that denies other processes that access mode.

=item EEXIST (File exists)

=item ERROR_FILE_EXISTS (The file exists)

[C<sopen()> only.] The I<$oflag> included C<O_CREAT | O_EXCL>, and the I<$file> already exists.

=item EINVAL (Invalid argument)

=item ERROR_ENVVAR_NOT_FOUND (The system could not find the environment option
that was entered)

The I<$oflag> or I<$shflag> argument was invalid.

=item EMFILE (Too many open files)

=item ERROR_TOO_MANY_OPEN_FILES (The system cannot open the file)

The maximum number of file descriptors has been reached.

=item ENOENT (No such file or directory)

=item ERROR_FILE_NOT_FOUND (The system cannot find the file specified)

The filename or path in I<$file> was not found.

=back

Other values may also be produced by various functions that are used within this
module whose possible error codes are not documented.

See L<C<$!>|perlvar/$!>, L<C<%!>|perlvar/%!>, L<C<$^E>|perlvar/$^E> and
L<Error Indicators|perlvar/"Error Indicators"> in L<perlvar>,
C<Win32::GetLastError()> and C<Win32::FormatMessage()> in L<Win32>, and L<Errno>
and L<Win32::WinError> for details on how to check these values.

=head1 EXAMPLES

=over 4

=item Open a file for reading, denying write access to other processes:

	fsopen(FH, $file, 'r', SH_DENYWR) or
		die "Can't read '$file' and take write-lock: $^E\n";

This example could be used for sharing a file amongst several processes for
reading, but protecting the reads from interference by other processes trying to
write the file.

=item Open a file for reading, denying write access to other processes, with
automatic open-retrying:

	$Win32::SharedFileOpen::Max_Time = 10;

	fsopen(FH, $file, 'r', SH_DENYWR) or
		die "Can't read '$file' and take write-lock: $^E\n";

This example could be used in the same scenario as above, but when we actually
I<expect> there to be other processes trying to write to the file, e.g. we are
reading a file that is being regularly updated. In this situation we expect to
get sharing violation errors from time to time, so we use I<$Max_Time> to
automatically have another go at reading the file (for up to 10 seconds at the
most) when that happens.

We may also want to increase I<$Win32::SharedFileOpen::Retry_Timeout> from its
default value of 250 milliseconds if the file is fairly large and we expect the
writer updating the file to take very long to do so.

=item Open a file for "update", denying read and write access to other
processes:

	fsopen(FH, $file, 'r+', SH_DENYRW) or
		die "Can't update '$file' and take read/write-lock: $^E\n";

This example could be used by a process to both read and write a file (e.g. a
simple database) and guard against other processes interfering with the reads or
being interfered with by the writes.

=item Open a file for writing if and only if it doesn't already exist, denying
write access to other processes:

	sopen(FH, $file, O_WRONLY | O_CREAT | O_EXCL, SH_DENYWR, S_IWRITE) or
		die "Can't create '$file' and take write-lock: $^E\n";

This example could be used by a process wishing to take an "advisory lock" on
some non-file resource that can't be explicitly locked itself by dropping a
"sentinel" file somewhere. The test for the non-existence of the file and the
creation of the file is atomic to avoid a "race condition". The file can be
written by the process taking the lock and can be read by other processes to
facilitate a "lock discovery" mechanism.

=item Open a temporary file for "update", denying read and write access to other
processes:

	sopen(FH, $file, O_RDWR | O_CREAT | O_TRUNC | O_TEMPORARY, SH_DENYRW,
			S_IWRITE) or
		die "Can't update '$file' and take write-lock: $^E\n";

This example could be used by a process wishing to use a file as a temporary
"scratch space" for both reading and writing. The space is protected from the
prying eyes of, and interference by, other processes, and is deleted when the
process that opened it exits, even when dying abnormally.

=back

=head1 BACKGROUND REFERENCE

This section gives some useful background reference on filehandles and indirect
filehandles.

=head2 Filehandles

The C<fsopen()> and C<sopen()> functions both expect either a filehandle or an
indirect filehandle as their first argument.

Using a filehandle:

	fsopen(FH, $file, 'r', SH_DENYWR) or
		die "Can't read '$file': $!\n";

is the simplest approach, but filehandles have a big drawback: they are global
in scope so they are always in danger of clobbering a filehandle of the same
name being used elsewhere. For example, consider this:

	fsopen(FH, $file1, 'r', SH_DENYWR) or
		die "Can't read '$file1': $!\n";

	while (<FH>) {
		chomp($line = $_);
		my_sub($line);
	}

	...

	close FH;

	sub my_sub($) {
		fsopen(FH, $file2, 'r', SH_DENYWR) or
			die "Can't read '$file2': $!\n";
		...
		close FH;
	}

The problem here is that when you open a filehandle that is already open it is
closed first, so calling "C<fsopen(FH, ...)>" in C<my_sub()> causes the
filehandle C<FH> which is already open in the caller to be closed first so that
C<my_sub()> can use it. When C<my_sub()> returns the caller will now find that
C<FH> is closed, causing the next read in the C<while { ... }> loop to fail. (Or
even worse, the caller would end up mistakenly reading from the wrong file if
C<my_sub()> hadn't closed C<FH> before returning!)

=head2 Localised Typeglobs and the C<*foo{THING}> Notation

One solution to this problem is to localise the typeglob of the filehandle in
question within C<my_sub()>:

	sub my_sub($) {
		local *FH;
		fsopen(FH, $file2, 'r', SH_DENYWR) or
			die "Can't read '$file2': $!\n";
		...
		close FH;
	}

but this has the unfortunate side-effect of localising all the other members of
that typeglob as well, so if the caller had global variables I<$FH>, I<@FH> or
I<%FH>, or even a subroutine C<FH()>, which C<my_sub()> needed then it no longer
has access to them either. (It does, on the other hand, have the rather nicer
side-effect that the filehandle is automatically closed when the localised
typeglob goes out of scope, so the "C<close FH;>" above is no longer necessary.)

This problem can also be addressed by using the so-called C<*foo{THING}>
syntax. C<*foo{THING}> returns a reference to the I<THING> member of the I<*foo>
typeglob. For example, C<*foo{SCALAR}> is equivalent to C<\$foo>, and
C<*foo{CODE}> is equivalent to C<\&foo>. C<*foo{IO}> (or the older, now
out-of-fashion notation C<*foo{FILEHANDLE}>) yields the actual internal
IO::Handle object that the C<*foo> typeglob contains, so with this we can
localise just the IO object, not the whole typeglob, so that we don't
accidentally hide more than we meant to:

	sub my_sub($) {
		local *FH{IO};
		fsopen(FH, $file2, 'r', SH_DENYWR) or
			die "Can't read '$file2': $!\n";
		...
		close FH;	# As in the example above, this is also not necessary
	}

However, this has a drawback as well: C<*FH{IO}> only works if C<FH> has already
been used as a filehandle (or some other IO handle), because C<*foo{THING}>
returns C<undef> if that particular I<THING> hasn't been seen by the compiler
yet (with the exception of when I<THING> is C<SCALAR>, which is treated
differently). This is fine in the example above, but would not necessarily have
been if the caller of C<my_sub()> hadn't used the filehandle C<FH> first, so
this approach would be no good if C<my_sub()> was to be put in a module to be
used by other callers too.

=head2 Indirect Filehandles

The answer to all of these problems is to use so-called indirect filehandles
instead of "normal" filehandles. An indirect filehandle is anything other than a
symbol being used in a place where a filehandle is expected, i.e. an expression
that evaluates to something that can be used as a filehandle, namely:

=over 4

=item A string

A name like C<'FH'> to be used as a symbolic reference to the typeglob whose IO
member is to be used as the filehandle.

=item A typeglob

Either a named typeglob like C<*FH>, or an anonymous typeglob in a scalar
variable (e.g. from C<Symbol::gensym()>), whose IO member is to be used as the
filehandle.

=item A reference to a typeglob

Either a hard reference like C<\*FH>, or a symbolic reference as in the first
case above, to a typeglob whose IO member is to be used as the filehandle.

=item A suitable IO object

Either the IO member of a typeglob obtained via the C<*foo{IO}> syntax, or an
instance of IO::Handle, or of IO::File or FileHandle (which are both just
sub-classes of IO::Handle).

=back

Of course, typeglobs are global in scope just like filehandles are, so if a
named typeglob, a reference (hard or symbolic) to a named typeglob or the IO
member of a named typeglob is used then we run into the same scoping problems
that we saw above with filehandles. The remainder of the above, however,
(namely, an anonymous typeglob in a scalar variable, or a suitable IO object)
finally give us the answer that we have been looking for.

So we can now write C<my_sub()> like this:

	sub my_sub($) {
		# Create "my $fh" here: see below
		fsopen($fh, $file2, 'r', SH_DENYWR) or
			die "Can't read '$file2': $!\n";
		...
		close $fh;		# Not necessary again
	}

where any of the following may be used to create "C<my $fh>":

	use Symbol;
	my $fh = gensym();

	use IO::Handle;
	my $fh = IO::Handle->new();

	use IO::File;
	my $fh = IO::File->new();

	use FileHandle;
	my $fh = FileHandle->new();

As we have noted in the code segment above, the "C<close $fh;>" is once again
not necessary: the filehandle is closed automatically when the lexical variable
I<$fh> is destroyed, i.e. when it goes out of scope (assuming there are no other
references to it).

However, there is still another point to bear in mind regarding the four
solutions shown above: they all load a good number of extra lines of code into
your program that might not otherwise be made use of. Note that FileHandle is a
sub-class of IO::File, which is in turn a sub-class of IO::Handle, so using
either of those sub-classes is particularly wasteful in this respect unless the
methods provided by them are going to be put to use. Even the IO::Handle class
still loads a number of other modules, including Symbol, so using the Symbol
module is certainly the best bet here if none of the IO::Handle methods are
required.

In our case, there is no additional overhead at all in loading the Symbol module
for this purpose because it is already loaded by this module itself anyway. In
fact, C<Symbol::gensym()>, imported by this module, is made available for export
from this module, so one can write:

	use Win32::SharedFileOpen qw(:DEFAULT gensym);
	my $fh = gensym();

to create "C<my $fh>" above.

=head2 The First-Class Filehandle Trick

Finally, there is another way to get an anonymous typeglob in a scalar variable
which is even leaner and meaner than using C<Symbol::gensym()>: the "First-Class
Filehandle Trick". It is described in an article by Mark-Jason Dominus called
"Seven Useful Uses of Local" which first appeared in The Perl Journal, and can
also be found (at the time of writing) on his website at the URL
F<http://perl.plover.com/local.html>. It consists simply of the following:

	my $fh = do { local *FH };

It works like this: the C<do { ... }> block simply executes the commands within
the block and returns the value of the last one. So in this case, the global
C<*FH> typeglob is temporarily replaced with a new glob that is C<local()> to
the C<do { ... }> block. The new, C<local()>, C<*FH> typeglob then goes out of
scope (i.e. is no longer accessible by that name) but is not destroyed because
it gets returned from the C<do { ... }> block. It is this, now anonymous,
typeglob that gets assigned to "C<my $fh>", exactly as we wanted.

Note that it is important that the typeglob itself, not a reference to it, is
returned from the C<do { ... }> block. This is because references to localised
typeglobs cannot be returned from their local scopes, one of the few places
in which typeglobs and references to typeglobs cannot be used interchangeably.
If we were to try to return a reference to the typeglob, as in:

	my $fh = do { \local *FH };

then I<$fh> would actually be a reference to the original C<*FH> itself, not the
temporary, localised, copy of it that existed within the C<do { ... }> block.
This means that if we were to use that technique twice to obtain two typeglob
references to use as two indirect filehandles then we would end up with them
both being references to the same typeglob (namely, C<*FH>) so that the two
filehandles would then clash.

If this trick is used only once within a program running under
"C<use warnings;>" that doesn't mention C<*FH> or any of its members anywhere
else then a warning like the following will be produced:

	Name "main::FH" used only once: possible typo at ...

This can be easily avoided by turning off that warning within the C<do { ... }>
block:

	my $fh = do { no warnings 'once'; local *FH };

For convenience, this solution is implemented by this module itself in the
function C<new_fh()>, so that one can now simply write:

	use Win32::SharedFileOpen qw(:DEFAULT new_fh);
	my $fh = new_fh();

The only downside to this solution is that any subsequent error messages
involving this filehandle will refer to C<Win32::SharedFileOpen::FH>, the
IO member of the typeglob that a temporary, localised, copy of was used. For
example, the program:

	use strict;
	use warnings;
	use Win32::SharedFileOpen qw(:DEFAULT new_fh);
	my $fh = new_fh();
	print $fh "Hello, world.\n";

outputs the warning:

	print() on unopened filehandle Win32::SharedFileOpen::FH at test.pl line 5.

If several filehandles are being used in this way then it can be confusing to
have them all referred to by the same name. (Do not be alarmed by this, though:
they are completely different anonymous filehandles which just happen to be
referred to by their original, but actually now out-of-scope, names.) If this is
a problem then consider using C<Symbol::gensym()> instead (see above): that
function uses a different name ('GEN0', 'GEN1', 'GEN2', ...) to generate each
anonymous typeglob from.

=head2 Auto-Vivified Filehandles

Note that all of the above discussion of filehandles and indirect filehandles
applies equally to Perl's built-in C<open()> and C<sysopen()> functions. It
should also be noted that those two functions both support the use of one other
value in the first argument that this module's C<fsopen()> and C<sopen()>
functions do not: the undefined value. The calls

	open my $fh, $file;
	sysopen my $fh, $file, O_RDONLY;

each auto-vivify "C<my $fh>" into something that can be used as an indirect
filehandle. (In fact, they currently [as of Perl 5.8.0] auto-vivify an entire
typeglob, but this may change in a future version of Perl to only auto-vivify
the IO member.) Any attempt to do likewise with this module's functions:

	fsopen(my $fh, $file, 'r', SH_DENYNO);
	sopen(my $fh, $file, O_RDONLY, SH_DENYNO);

causes the functions to C<croak()>.

=head1 EXPORTS

The following symbols are, or can be, exported by this module:

=over 4

=item Default Exports

C<fsopen>,
C<sopen>;

C<O_APPEND>,
C<O_BINARY>,
C<O_CREAT>,
C<O_EXCL>,
C<O_NOINHERIT>,
C<O_RANDOM>,
C<O_RAW>,
C<O_RDONLY>,
C<O_RDWR>,
C<O_SEQUENTIAL>,
C<O_SHORT_LIVED>,
C<O_TEMPORARY>,
C<O_TEXT>,
C<O_TRUNC>,
C<O_WRONLY>;

C<S_IREAD>,
C<S_IWRITE>;

C<SH_DENYNO>,
C<SH_DENYRD>,
C<SH_DENYRW>,
C<SH_DENYWR>.

=item Optional Exports

C<gensym>,
C<new_fh>;

C<INFINITE>,
C<$Max_Time>,
C<$Max_Tries>,
C<$Retry_Timeout>.

=item Export Tags

=over 4

=item C<:oflags>

C<O_APPEND>,
C<O_BINARY>,
C<O_CREAT>,
C<O_EXCL>,
C<O_NOINHERIT>,
C<O_RANDOM>,
C<O_RAW>,
C<O_RDONLY>,
C<O_RDWR>,
C<O_SEQUENTIAL>,
C<O_SHORT_LIVED>,
C<O_TEMPORARY>,
C<O_TEXT>,
C<O_TRUNC>,
C<O_WRONLY>.

=item C<:pmodes>

C<S_IREAD>,
C<S_IWRITE>.

=item C<:shflags>

C<SH_DENYNO>,
C<SH_DENYRD>,
C<SH_DENYRW>,
C<SH_DENYWR>.

=item C<:retry>

C<INFINITE>,
C<$Max_Time>,
C<$Max_Tries>,
C<$Retry_Timeout>.

=back

=back

=head1 DEPENDENCIES

The following modules are C<use()>'d by this module:

=over 4

=item Standard Modules

Carp,
Exporter,
Symbol,
Win32,
XSLoader.

=item CPAN Modules

Win32::WinError (part of the "libwin32" distribution).

=item Other Modules

I<None>.

=back

=head1 COMPATIBILITY

Prior to version 2.00 of this module, C<fsopen()> and C<sopen()> both created a
filehandle and returned it to the caller. (C<undef> was returned instead on
failure.)

As of version 2.00 of this module, the arguments and return values of these two
functions now more closely resemble those of the Perl built-in functions
C<open()> and C<sysopen()>. Specifically, they now both expect a
L<filehandle|"Filehandles"> or an L<indirect filehandle|"Indirect Filehandles">
as their first argument and they both return a Boolean value to indicate success
or failure.

B<THIS IS AN INCOMPATIBLE CHANGE. EXISTING SOFTWARE THAT USES THESE FUNCTIONS
WILL NEED TO BE MODIFIED.>

=head1 BUGS AND CAVEATS

I<None known>.

=head1 SEE ALSO

L<perlfunc/open>,
L<perlfunc/sysopen>,
L<perlopentut>;

L<Fcntl>,
L<FileHandle>,
L<IO::File>,
L<IO::Handle>,
L<Symbol>,
L<Win32API::File>.

In particular, the Win32API::File module (part of the "libwin32" distribution)
contains an interface to a (lower level) Win32 API function,
L<C<CreateFile()>|Win32API::File/CreateFile>, which provides similar (and more)
capabilities but using a completely different set of arguments which are
unfamiliar to unseasoned Microsoft developers. A more Perl-friendly wrapper
function, L<C<createFile()>|Win32API::File/createFile>, is also provided but
does not entirely alleviate the pain.

=head1 ACKNOWLEDGEMENTS

Some of the XS code used in the re-write for version 3.00 is based on that in
the standard library module VMS::Stdio (version 2.3).

Thanks to Nick Ing-Simmons for help in getting this XS to build under different
flavours of Perl (all "stable" Perls from 5.6.0 onwards, both with and without
PERL_IMPLICIT_CONTEXT and/or PERL_IMPLICIT_SYS enabled, are now supported), and
for help in fixing a text mode/binary mode bug in the fsopen() function.

=head1 AUTHOR

Steve Hay E<lt>shay@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENCE

Copyright (c) 2001-2003, Steve Hay. All rights reserved.

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=head1 VERSION

Win32::SharedFileOpen, Version 3.14

=head1 HISTORY

See the file F<Changes> in the original distribution archive,
F<Win32-SharedFileOpen-3.14.tar.gz>.

=cut

#-------------------------------------------------------------------------------
