#!/usr/bin/perl

# (C) Daniel Kasak: dan@entropy.homelinux.org
# See COPYRIGHT file for full license

# See 'man Gtk2::Ex::DBI' for full documentation ... or of course continue reading

package Gtk2::Ex::DBI;

use strict;
use warnings;

use POSIX;
use Glib qw/TRUE FALSE/;

use Gtk2::Ex::Dialogs (
			destroy_with_parent	=> TRUE,
			modal			=> TRUE,
			no_separator		=> FALSE
		      );

BEGIN {
	$Gtk2::Ex::DBI::VERSION = '2.0';
}

sub new {
	
	my ( $class, $req ) = @_;
	
	# Assemble object from request
	my $self = {
		dbh			=> $$req{dbh},					# A database handle
		primary_key		=> $$req{primary_key},				# The primary key ( needed for inserts / updates )
		sql			=> $$req{sql},					# A hash of SQL related stuff
		schema			=> $$req{schema},				# The 'schema' to use to get column info from
		form			=> $$req{form},					# The Gtk2-GladeXML *object* we're using
		formname		=> $$req{formname},				# The *name* of the window ( needed for dialogs to work properly )
		readonly		=> $$req{readonly} || FALSE,			# Whether changes to the table are allowed
		apeture			=> $$req{apeture} || 100,			# The number of records to select at a time
		on_current		=> $$req{on_current},				# A reference to code that is run when we move to a new record
		on_apply		=> $$req{on_apply},				# A reference to code that is run *after* the 'apply' method is called
		calc_fields		=> $$req{calc_fields},				# Calculated field definitions ( HOH )
		defaults		=> $$req{defaults},				# Default values ( HOH )
		disable_find		=> $$req{disable_find} || FALSE,		# Do we build the right-click 'find' item on GtkEntrys?
		disable_full_table_find	=> $$req{disable_full_table_find} || FALSE,	# Can the user search the whole table ( sql=>{from} ) or only the current recordset?
		quiet			=> $$req{quiet} || FALSE,			# A flag to silence warnings such as missing widgets
		changed			=> FALSE,					# A flag indicating that the current record has been changed
		changelock		=> FALSE,					# Prevents the 'changed' flag from being set when we're moving records
		constructor_done	=> FALSE,					# A flag that indicates whether the new() method has completed yet
		debug			=> $$req{debug} || FALSE			# Dump info to terminal
	};
	
	bless $self, $class;
	
	my $legacy_warnings;
	
	# Reconstruct sql object if needed
	if ( $$req{sql_select} || $$req{table} || $$req{sql_where} || $$req{sql_order_by} ) {
		
		# Strip out SQL directives
		if ( $$req{sql_select} ) {
			$$req{sql_select}	=~ s/^select //i;
		}
		if ( $$req{sql_table} ) {
			$$req{sql_table}	=~ s/^from //i;
		}
		if ( $$req{sql_where} ) {
			$$req{sql_where}	=~ s/^where //i;
		}
		if ( $$req{sql_order_by} ) {
			$$req{sql_order_by}	=~ s/^order by //i;
		}
		
		# Assemble things
		my $sql = {
					select		=> $$req{sql_select},
					from		=> $$req{table},
					where		=> $$req{sql_where},
					order_by	=> $$req{sql_order_by}
		};
		
		$self->{sql} = $sql;
		
		$legacy_warnings = " - use the new sql object for the SQL string\n";
		
	}
	
	# Primary Key
	if ( $$req{primarykey} ) {
		$self->{primary_key} = $$req{primarykey};
		$legacy_warnings .= " - primarykey renamed to primary_key\n";
	}
	
	if ( $legacy_warnings || $self->{legacy_mode} ) {
		print "\n\n **** Gtk2::Ex::DBI starting in legacy mode ***\n";
		print "While quite some effort has gone into supporting this, it would be wise to take action now.\n";
		print "Warnings triggered by your request:\n$legacy_warnings\n";
	}
	
	# Cache the fieldlist array so we don't have to continually query the DB server for it
	my $sth;
	
	eval {
		$sth = $self->{dbh}->prepare(
			"select " . $self->{sql}->{select} . " from " . $self->{sql}->{from} . " where 0=1")
				|| die $self->{dbh}->errstr;
	};
	
	if ($@) {
		Gtk2::Ex::Dialogs::ErrorMsg->new_and_run(
								title	=> "Error in Query!",
								text	=> "DB Server says:\n$@"
							);
		return FALSE;
	}
	
	eval {
		$sth->execute || die $self->{dbh}->errstr;
	};
	
	if ($@) {
		Gtk2::Ex::Dialogs::ErrorMsg->new_and_run(
								title	=> "Error in Query!",
								text	=> "DB Server says:\n$@"
							);
		return FALSE;
		
	}
	
	$self->{fieldlist} = $sth->{'NAME'};
	
	$sth->finish;
	
	# Fetch column_info for current table
	$sth = $self->{dbh}->column_info ( undef, $self->{schema}, $self->{sql}->{from}, '%' );
	
	while ( my $column_info_row = $sth->fetchrow_hashref ) {
		# Set the primary key if we find one ( MySQL only at present ),
		# but only if one hasn't been defined yet ( could be a multi-table query )
		if ( $column_info_row->{mysql_is_pri_key} && ! $self->{primary_key} ) {
			$self->{primary_key} = $column_info_row->{COLUMN_NAME};
		}
		# Loop through the list of columns from the database, and
		# add only columns that we're actually dealing with
		for my $field ( @{$self->{fieldlist}} ) {
			if ( $column_info_row->{COLUMN_NAME} eq $field ) {
				$self->{column_info}->{$field} = $column_info_row;
				last;
			}
		}
	}
	
	$sth->finish;
	
	$self->query;
	
	# We connect a few little goodies to various widgets ...
	
	# - Connect our 'changed' method to whatever signal each widget emits when it's 'changed'
	
	# - Gtk's ComboBoxEntry has a bug where it only registers a change and set's the currect iter if
	# the combo box functionality is used. If the Entry functionality is used ( ie someone types a
	# string that matches one in the list ), NOTHING is registered, and the active iter is not set.
	# We *NEED* to work around this until the bug is fixed, otherwise ComboBoxEntrys are horribly broken.
	# Therefore we connect the sub set_active_iter_for_broken_combo_box to the on_focus_out event.
	
	# See http://bugzilla.gnome.org/show_bug.cgi?id=156017
	# Note that while the above bug page shows this bug as being 'FIXED', I've yet to see this
	# fix materialise in Gtk2 - when it does I will limit our work-around to those affected
	# versions of Gtk2.
	
	# - Use the populate-popup signal of Gtk2::Entry widgets to add the 'find' menu item
	
	# We also keep an array of widgets and signal ids so that we can disconnect all signal handlers
	# and cleanly destroy ourselves when requested
	
	foreach my $field ( @{$self->{fieldlist}} ) {
		my $widget = $self->{form}->get_widget($field);
		if (defined $widget) {
			my $type = (ref $widget);
			if ($type eq "Gtk2::Calendar") {
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->signal_connect( day_selected	=>	sub { $self->changed; } )
				];
			} elsif ($type eq "Gtk2::ToggleButton") {
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->signal_connect( toggled	=>	sub { $self->changed; } )
				];
			} elsif ($type eq "Gtk2::TextView") {
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->get_buffer->signal_connect( changed =>	sub { $self->changed; } )
				];
			} elsif ($type eq "Gtk2::ComboBoxEntry") {
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->signal_connect( changed	=>	sub { $self->changed; } )
				];
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->get_child->signal_connect( changed =>	sub { $self->set_active_iter_for_broken_combo_box($widget) } )
				];
			} elsif ($type eq "Gtk2::CheckButton") {
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->signal_connect( toggled	=>	sub { $self->changed; } )
				];
			} elsif ($type eq "Gtk2::Entry") {
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->signal_connect( changed	=>	sub { $self->changed; } )
				];
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->signal_connect_after( 'populate-popup'	=> sub { $self->build_right_click_menu(@_); } )
				];
			} else {
				push @{$self->{objects_and_signals}},
				[
					$widget,
					$widget->signal_connect( changed	=>	sub { $self->changed; } )
				];
			}
		}
	}
	
	$self->{spinner} = $self->{form}->get_widget("RecordSpinner");
	
	if ( $self->{spinner} ) {
		
		$self->{record_spinner_value_changed_signal}
			= $self->{spinner}->signal_connect( value_changed			=> sub {
				$self->{spinner}->signal_handler_block($self->{record_spinner_value_changed_signal});
				$self->move( undef, $self->{spinner}->get_text - 1 );
				$self->{spinner}->signal_handler_unblock($self->{record_spinner_value_changed_signal});
				return TRUE;
			}
						 );
		
		push @{$self->{objects_and_signals}},
		[
			$self->{spinner},
			$self->{record_spinner_value_changed_signal}
		];
		
	}
	
	# Check recordset status when window is destroyed
	push @{$self->{objects_and_signals}},
	[
		$self->{form}->get_widget($self->{formname}),
		$self->{form}->get_widget($self->{formname})->signal_connect(	delete_event		=> sub {
			if ( $self->{changed} ) {
				my $answer = Gtk2::Ex::Dialogs::Question->new_and_run(
					title	=> "Apply changes to " . $self->{sql}->{from} . " before closing?",
					text	=> "There are changes to the current record ( "
						. $self->{sql}->{from} . " )\nthat haven't yet been applied.\n"
						. "Would you like to apply them before closing the form?"
										     );
				# We return FALSE to allow the default signal handler to
				# continue with destroying the window - all we wanted to do was check
				# whether to apply records or not
				if ( $answer ) {
					if ( $self->apply ) {
						return FALSE;
					} else {
						# ie don't allow the form to close if there was an error applying
						return TRUE;
					}
				} else {
					return FALSE;
				}
			}
		} )
	];
	
	$self->{constructor_done} = TRUE;
	
	$self->set_record_spinner_range;
	
	return $self;
	
}

sub destroy_signal_handlers {
	
	my $self = shift;
	
	foreach my $set ( @{$self->{objects_and_signals}} ) {
		$$set[0]->signal_handler_disconnect( $$set[1] );
	}
	
	return TRUE;
	
}

sub destroy_self {
	
	undef $_[0];
	
}

sub destroy {
	
	my $self = shift;
	
	$self->destroy_signal_handlers;
	$self->destroy_self;
	
}

sub fieldlist {
	
	# Provide legacy fieldlist method
	
	my $self = shift;
	
	return $self->{fieldlist};
	
}

sub query {
	
	# Query / Re-query
	
	my ( $self, $where_object ) = @_;
	
	# In version 2.x, $where_object *should* be a hash, containing the keys:
	#  - where
	#  - bind_values
	
	# Update database from current hash if necessary
	if ($self->{changed} == TRUE) {
		
		my $answer = ask Gtk2::Ex::Dialogs::Question(
				    title	=> "Apply changes to " . $self->{sql}->{from} . " before querying?",
				    text	=> "There are outstanding changes to the current record ( " . $self->{sql}->{from} . " )."
							. " Do you want to apply them before running a new query?"
							    );

		if ($answer) {
		    if ( ! $self->apply ) {
			return FALSE; # Apply method will already give a dialog explaining error
		    }
		}
		
	}
	
	# Deal with legacy mode - the query method used to accept an optional where clause
	if ( ref( $where_object ) ne "HASH" ) {
		# Legacy mode
		# Strip 'where ' out of clause
		if ( $where_object ) {
			$where_object =~ s/^where //i;
		}
		# Transfer new sql_where clause if defined
		$self->{sql}->{where} = $where_object;
		# Also remove any bound values if called in legacy mode
		$self->{sql}->{bind_values} = undef;
	} else {
		# NOT legacy mode
		if ( $where_object->{where} ) {
			$self->{sql}->{where} = $where_object->{where};
		}
		if ( $where_object->{bind_values} ) {
			$self->{sql}->{bind_values} = $where_object->{bind_values};
		}
	}
	
	$self->{keyset_group} = undef;
	$self->{slice_position} = undef;
	
	# Get an array of primary keys
	my $sth;
	
	my $local_sql =
		"select " . $self->{primary_key}
		. " from " . $self->{sql}->{from};
	
	# Add where clause if defined
	if ( $self->{sql}->{where} ) {
		$local_sql .= " where " . $self->{sql}->{where};
	}
	
	# Add order by clause of defined
	if ( $self->{sql}->{order_by} ) {
		$local_sql .= " order by " . $self->{sql}->{order_by};
	}
						
	eval {
		$sth = $self->{dbh}->prepare( $local_sql )
			|| die $self->{dbh}->errstr;
	};
	
	if ($@) {
		Gtk2::Ex::Dialogs::ErrorMsg->new_and_run(
								title	=> "Error in Query!",
								text	=> "DB Server says:\n$@"
							);
		return FALSE;
	}
	
	eval {
		if ( $self->{sql}->{bind_values} ) {
			$sth->execute( @{$self->{sql}->{bind_values}} ) || die $self->{dbh}->errstr;
		} else {
			$sth->execute || die $self->{dbh}->errstr;
		}
	};
	
	if ($@) {
		Gtk2::Ex::Dialogs::ErrorMsg->new_and_run(
								title	=> "Error in Query!",
								text	=> "DB Server says:\n$@"
							);
		return FALSE;
	}
	
	$self->{keyset} = ();
	$self->{records} = ();
	
	while (my @row = $sth->fetchrow_array) {
		push @{$self->{keyset}}, $row[0];
	}
	
	$sth->finish;
	
	if ( $self->{spinner} ) {
		$self->set_record_spinner_range;
	}
	
	$self->move( 0, 0 );
	
	$self->set_record_spinner_range;
	
	return TRUE;
	
}

sub insert {
	
	# Inserts a record at the end of the *in-memory* recordset.
	# I'm using an exclamation mark ( ! ) to indicate that the record isn't yet in the DB server.
	# When the 'apply' method is called, if a '!' is in the primary key's place,
	# an *insert* is triggered instead of an *update*.
	
	my $self = shift;
	my $newposition = $self->count; # No need to add one, as the array starts at zero.
	
	# Open RecordSpinner range
	if ( $self->{spinner} ) {
		$self->{spinner}->signal_handler_block(		$self->{record_spinner_value_changed_signal} );
		$self->{spinner}->set_range( 1, $self->count + 1 );
		$self->{spinner}->signal_handler_unblock(	$self->{record_spinner_value_changed_signal} );
	}
	
	if ( ! $self->move( 0, $newposition ) ) {
		warn "Insert failed ... probably because the current record couldn't be applied\n";
		return FALSE;
	}
	
	# Assemble new record and put it in place
	$self->{records}[$self->{slice_position}] = $self->assemble_new_record;
	
	# Finally, paint the current recordset onto the widgets
	# This is the 2nd time this is called in this sub ( 1st from $self->move ) but we need to do it again to paint the default values
	$self->paint;
	
	return TRUE;
	
}

sub assemble_new_record {
	
	# This sub assembles a new hash record and sets default values
	
	my $self = shift;
	
	my $new_record;
	
	# First, we create fields with default values from the database ...
	foreach my $field ( keys %{$self->{column_info}} ) {
		$new_record->{$field} = $self->{column_info}->{$field}->{COLUMN_DEF}; # COLUMN_DEF is DBI speak for 'column default'
	}
	
	# ... and then we set user-defined defaults
	foreach my $field ( keys %{$self->{defaults}} ) {		
		$new_record->{$field} = $self->{defaults}->{$field};
	}
	
	# Finally, set the insertion marker ( but don't set the changed flag until the user actually changes something )
	$new_record->{$self->{primary_key}} = "!";
	
	return $new_record;
	
}

sub count {
	
	# Counts the records ( items in the keyset array ).
	# Note that this returns the REAL record count, and keep in mind that the first record is at position 0.
	
	my $self = shift;
	
	if ( ref($self->{keyset}) eq "ARRAY" ) {
		return scalar @{$self->{keyset}};
	} else {
		return 0;
	}
	
}

sub paint {
	
	my $self = shift;
	
	# Set the changelock so we don't trigger more changes
	$self->{changelock} = TRUE;
	
	foreach my $field ( @{$self->{fieldlist}} ) {
		
		my $widget = $self->{form}->get_widget($field);
		
		if (!defined $widget) {
			
			if ( ! $self->{quiet} ) {
				warn "*** Field $field is missing a widget! ***\n";
			}
			
		} else {
			
			my $type = (ref $widget);
			
			if ($type eq "Gtk2::Calendar") {
				
				if ($self->{records}[$self->{slice_position}]->{$field}) {
					
					my $year = substr($self->{records}[$self->{slice_position}]->{$field}, 0, 4);
					my $month = substr($self->{records}[$self->{slice_position}]->{$field}, 5, 2);
					my $day = substr($self->{records}[$self->{slice_position}]->{$field}, 8, 2);
					
					# NOTE! NOTE! Apparently GtkCalendar has the months starting at ZERO!
					# Therefore, take one off the month...
					$month --;
					
					if ($month != -1) {
						$widget->select_month($month, $year);
						$widget->select_day($day);
					} else {
						# Select the current month / year
						( $month, $year ) = (localtime())[4, 5];
						$year += 1900;
						$month += 1;
						$widget->select_month($month, $year);        
						# But de-select the day
						$widget->select_day(0);
					}
					
				} else {
					
					$widget->select_day(0);
					
				}
				
			} elsif ($type eq "Gtk2::ToggleButton") {
				
				$widget->set_active($self->{records}[$self->{slice_position}]->{$field});
				
			} elsif ($type eq "Gtk2::ComboBoxEntry") {
				
				# This is some ugly stuff. Gtk2 doesn't support selecting an iter in a model based on the string
				
				# See http://bugzilla.gnome.org/show_bug.cgi?id=149248
				
				# TODO: if we can't get above bug resolved, perhaps load the ID / value pairs into something that supports
				# rapid searching so we don't have to loop through the entire list, which could be *very* slow if the list is large
				
				my $iter = $widget->get_model->get_iter_first;
				$widget->get_child->set_text("");                
				
				while ($iter) {
					if ( ( defined $self->{records}[$self->{slice_position}]->{$field} ) &&
						( $self->{records}[$self->{slice_position}]->{$field} eq $widget->get_model->get( $iter, 0) ) ) {
							$widget->set_active_iter($iter);
							last;
					}
					$iter = $widget->get_model->iter_next($iter);
				}
				
			} elsif ($type eq "Gtk2::TextView") {
				
				$widget->get_buffer->set_text($self->{records}[$self->{slice_position}]->{$field});
				
			} elsif ($type eq "Gtk2::CheckButton") {
				
				$widget->set_active($self->{records}[$self->{slice_position}]->{$field});
				
			} else {
				
				# Assume everything else has a 'set_text' method. Add more types if necessary...
				# Little test to make perl STFU about 'Use of uninitialized value in subroutine entry'
				if ( defined($self->{records}[$self->{slice_position}]->{$field}) ) {
						$widget->set_text($self->{records}[$self->{slice_position}]->{$field});
				} else {
					$widget->set_text("");
				}
				
			}
		}
	}
	
	# Paint calculated fields
	$self->paint_calculated;
	
	# Execute external on_current code ( only if we have been constructed AND returned to calling code 1st - otherwise references to us won't work )
	if ( $self->{on_current} && $self->{constructor_done} ) {
		$self->{on_current}();
	}
	
	# Unlock the changelock
	$self->{changelock} = FALSE;
	
}

sub move {
	
	# Moves to the requested position, either as an offset from the current position,
	# or as an absolute value. If an absolute value is given, it overrides the offset.
	# If there are changes to the current record, these are applied to the DB server first.
	# Returns TRUE ( 1 ) if successful, FALSE ( 0 ) if unsuccessful.
	
	my ( $self, $offset, $absolute ) = @_;
	
	# Update database from current hash if necessary
	if ($self->{changed} == TRUE) {
		my $result = $self->apply;
		if ( $result == FALSE ) {
			# Update failed. If RecordSpinner exists, set it to the current position PLUS ONE.
			if ( $self->{spinner} ) {
				$self->{spinner}->signal_handler_block(		$self->{record_spinner_value_changed_signal});
				$self->{spinner}->set_text( $self->position + 1 );
				$self->{spinner}->signal_handler_block(		$self->{record_spinner_value_changed_signal});
			}
			return FALSE;
		}
	}
	
	# Update 'lbl_RecordStatus'. This seems to be the safest ( or most accurate ) place to do this...
	my $recordstatus = $self->{form}->get_widget("lbl_RecordStatus");
	
	if (defined $recordstatus) {
		$recordstatus->set_markup('<b>Synchronized</b>');
	}
	
	my ( $new_keyset_group, $new_position);
	
	if ( defined $absolute ) {
		$new_position = $absolute;
	} else {
		$new_position = ( $self->position || 0 ) + $offset;
		# Make sure we loop around the recordset if we go out of bounds.
		if ( $new_position < 0 ) {
			$new_position = $self->count - 1;
		} elsif ( $new_position > $self->count - 1 ) {
			$new_position = 0;
		}
	}
	
	# Check if we now have a sane $new_position.
	# Some operations ( insert, then revert part-way through ... or move backwards when there are no records ) can cause this.
	if ( $new_position < 0 ) {
		$new_position = 0;
	}
	
	# Check if we need to roll to another slice of our recordset
	$new_keyset_group = int($new_position / $self->{apeture} );
	
	if (defined $self->{slice_position}) {
		if ( $self->{keyset_group} != $new_keyset_group ) {
			$self->{keyset_group} = $new_keyset_group;
			$self->fetch_new_slice;
		};
	} else {
		$self->{keyset_group} = $new_keyset_group;
		$self->fetch_new_slice;
	}
	
	$self->{slice_position} = $new_position - ( $new_keyset_group * $self->{apeture} );
	
	$self->paint;
	
	# Set the RecordSpinner
	if ( $self->{spinner} ) {
		$self->{spinner}->signal_handler_block(		$self->{record_spinner_value_changed_signal} );
		$self->{spinner}->set_text( $self->position + 1 );
		$self->{spinner}->signal_handler_unblock(	$self->{record_spinner_value_changed_signal} );
	}
	
	return TRUE;
	
}

sub fetch_new_slice {
	
	# Fetches a new 'slice' of records ( based on the aperture size )
	
	my $self = shift;
	
	# Get max value for the loop ( not sure if putting a calculation inside the loop def slows it down or not )
	my $lower = $self->{keyset_group} * $self->{apeture};
	my $upper = ( ($self->{keyset_group} + 1) * $self->{apeture} ) - 1;
	
	# Don't try to fetch records that aren't there ( at the end of the recordset )
	my $keyset_count = $self->count; # So we don't keep running $self->count...
	
	if ( $keyset_count == 0 ) {
		
		# There are no records.
		
		# First, we have to delete anything in $self->{records}
		# This would *usually* just be overwritten if we actually got a keyset above,
		# but since we didn't, we have to make sure there's nothing left
		$self->{records} = ();
		
		# Now create a new record ( with defaults and insertion marker )
		
		# Note that we don't set the changed marker at this point, so if the user starts entering data,
		# this is treated as an inserted record. However if the user doesn't enter data, and does something else
		# ( eg another query ), this record will simply be discarded ( changed marker = 0 )
		
		# Keep in mind that this doens't take into account other requirements for a valid record ( eg foreign keys )
		push @{$self->{records}}, $self->assemble_new_record;
		
	} else {
		
		if ($upper > $keyset_count) {
			$upper = $keyset_count - 1;
		}
		
		my $key_list;
		
		for ( my $counter = $lower; $counter < $upper+1; $counter++ ) {
			$key_list .= " " . $self->{keyset}[$counter] . ",";
		}
		
		# Chop off trailing comma
		chop($key_list);
		
		# Assemble query
		my $local_sql = "select " . $self->{sql}->{select};
		
		# Check we have a primary key ( or a wildcard ) in sql_select; append primary key if we don't - we need it
		if ( $self->{sql}->{select} !~ /$self->{primary_key}/ && $self->{sql}->{select} !~ /[\*|%]/ ) {
			$local_sql .= ", " . $self->{primary_key};
		}
		
		$local_sql .= " from " . $self->{sql}->{from}
			. " where " . $self->{primary_key} . " in ($key_list )";
		
		if ( $self->{sql}->{order_by} ) {
			$local_sql .= " order by " . $self->{sql}->{order_by};
		}
		
		eval {
			$self->{records} = $self->{dbh}->selectall_arrayref (
				$local_sql,	{Slice=>{}}
			) || die "Error in SQL:\n$local_sql";
		};
		
		if ( $@ ) {
			Gtk2::Ex::Dialogs::ErrorMsg->new_and_run(
									title	=> "Error fetching record slice!",
									text	=> "Database server says:\n" . $@
								);
			return FALSE;
		}
		
		return TRUE;
		
	}
	
}

sub apply {
	
	# Applys the data from the current form back to the DB server.
	# Returns TRUE ( 1 ) if successful, FALSE ( 0 ) if unsuccessful.
	
	my $self = shift;
	
	if ( $self->{readonly} == TRUE ) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
							title	=> "Read Only!",
							text	=> "Sorry. This form is open\nin read-only mode!"
						       );
		return FALSE;
	}
	
	my $fieldlist = "";
	my @bind_values = ();
	
	my $inserting = FALSE; # Flag that tells us whether we're inserting or updating
	my $placeholders;  # We need to append to the placeholders while we're looping through fields, so we know how many fields we actually have
	
	if ( $self->{records}[$self->{slice_position}]->{$self->{primary_key}} eq "!" ) {
		$inserting = TRUE;
	}
	
	foreach my $field ( @{$self->{fieldlist}} ) {
		
		if ( $self->{debug} ) {
			print "Processing field $field ...\n";
		}
		
		my $current_value = undef;
		
		my $widget = $self->{form}->get_widget($field);
		
		if ( defined $widget ) {
			
			if ($inserting) {
				$fieldlist .= " $field,";
				$placeholders .= " ?,";
			} else {
				$fieldlist .= " $field=?,";
			}
			
			my $type = (ref $widget);
			
			if ( $self->{debug} ) {
				print "   ... widget type: $type\n";
			}
			
			if ( $type eq "Gtk2::Calendar" ) {
				
				my ( $year, $month, $day ) = $widget->get_date;
				my $date;
				
				if ( $day > 0 ) {
					
					# NOTE! NOTE! Apparently GtkCalendar has the months starting at ZERO!
					# Therefore, add one to the month...
					$month ++;
					
					# Pad the $month and $day values
					if (length($month) == 1) {
						$month = "0" . $month;
					}
					
					if (length($day) == 1) {
						$day = "0" . $day;
					}
					
					$date = $year . "-" . $month . "-" . $day;
					
				} else {
					$date = undef;
				}
				
				$current_value = $date;
				
				
			} elsif ( $type eq "Gtk2::ToggleButton" ) {
				
				if ( $widget->get_active ) {
					$current_value = 1;
				} else {
					$current_value = 0;
				}
				
			} elsif ( $type eq "Gtk2::ComboBoxEntry" ) {   
				
				my $iter = $widget->get_active_iter;                
				
				# If $iter is defined ( ie something is selected ), push the ID of the selected row
				# onto @bind_values,  otherwise test the column type.
				# If we find a "Glib::Int" column type, we push a zero onto @bind_values otherwise 'undef'
				
				if ( defined $iter ) {
					$current_value = $widget->get_model->get( $iter, 0 );
				} else {                    
					my $columntype = $widget->get_model->get_column_type(0);                    
					if ( $columntype eq "Glib::Int" ) {
						$current_value = 0;
					} else {
						$current_value = undef;
					}
				}
				
			} elsif ($type eq "Gtk2::TextView") {
				
				my $textbuffer = $widget->get_buffer;
				my ( $start_iter, $end_iter ) = $textbuffer->get_bounds;
				$current_value = $textbuffer->get_text( $start_iter, $end_iter, 1 );
				
			} elsif ($type eq "Gtk2::CheckButton") {
				
				if ($widget->get_active) {
					$current_value = 1;
				} else {
					$current_value = 0;
				}
				
			} else {
				
				my $txt_value = $self->{form}->get_widget($field)->get_text;
				
				if ($txt_value || $txt_value eq "0") { # Don't push an undef value just because our field has a zero in it
					$current_value = $txt_value;
				} else {
					$current_value = undef;
				}
				
			}
			
			push @bind_values, $current_value;
			
			if ( $self->{debug} ) {
				print "   ... value: $current_value\n\n";
			}
			
		}
	}
	
	chop($fieldlist); # Chop off trailing comma
	
	my $update_sql;
	
	if ($inserting) {
		chop($placeholders); # Chop off trailing comma
		$update_sql = "insert into " .$self->{sql}->{from} . " ( $fieldlist ) values ( $placeholders )";
	} else {
		push @bind_values, $self->{records}[$self->{slice_position}]->{$self->{primary_key}};
		$update_sql = "update " . $self->{sql}->{from} . " set $fieldlist where " . $self->{primary_key} . "=?";
	}
	
	if ( $self->{debug} ) {
		print "Final SQL:\n$update_sql\n\n";
		for my $value ( @bind_values ) {
			print " bound_value: $value\n";
		}
	}
	
	my $sth = $self->{dbh}->prepare($update_sql);
	
	# Evaluate the results of the update.
	eval {
		$sth->execute (@bind_values) || die $self->{dbh}->errstr;
	};
	
	$sth->finish;
	
	# If the above failed, there will be something in the special variable $@
	if ($@) {
			# Dialog explaining error...
			new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
									title   => "Error updating recordset!",
									text    => "Database Server says:\n" . $@
							       );
			warn "Error updating recordset:\n$update_sql\n@bind_values\n" . $@ . "\n\n";
			return FALSE;
	}
	
	my $recordstatus = $self->{form}->get_widget("lbl_RecordStatus");
	
	if (defined $recordstatus) {
		$recordstatus->set_markup('<b>Synchronized</b>');
	}
	
	# If this was an INSERT, we need to fetch the primary key value and apply it to the local slice, and also append the primary key to the keyset
	if ($inserting) {
		
		my $inserted_id = $self->last_insert_id;
		
		$self->{records}[$self->{slice_position}]->{$self->{primary_key}} = $inserted_id;
		push @{$self->{keyset}}, $inserted_id;
		
		# Apply primary key to form ( if field exists )
		my $widget = $self->{form}->get_widget($self->{primary_key});
		
		if ($widget) {
			$widget->set_text($inserted_id); # Assuming the widget has a set_text method of course ... can't see when this wouldn't be the case
		}
		
		$self->{changelock} = FALSE;
		$self->set_record_spinner_range;
		$self->{changelock} = FALSE;
		
	}
	
	# SQL update successfull. Now apply update to local array. Comments ommitted, but logic is the same as above.
	
	foreach my $field ( @{$self->{fieldlist}} ) {
		
		my $widget = $self->{form}->get_widget($field);
		
		if (defined $widget) {
			
			my $type = (ref $widget);
			
			if ($type eq "Gtk2::Calendar") {
				
				my ( $year, $month, $day ) = $widget->get_date;
				my $date;
				
				if ( $day > 0 ) {
					$month ++;
					if ( length($month) == 1 ) {
						$month = "0" . $month;
					}
					if ( length($day) == 1 ) {
						$day = "0" . $day;
					}
					$date = $year . "-" . $month . "-" . $day;
				} else {
					$date = undef;
				}
				
				$self->{records}[$self->{slice_position}]->{$field}=$date;
				
			} elsif ($type eq "Gtk2::ToggleButton") {
				
				if ($widget->get_active) {
					$self->{records}[$self->{slice_position}]->{$field} = 1;
				} else {
					$self->{records}[$self->{slice_position}]->{$field} = 0;
				}
				
			} elsif ( $type eq "Gtk2::ComboBoxEntry" ) {
				
				my $iter = $widget->get_active_iter;
				
				if ( defined $iter ) {
					$self->{records}[$self->{slice_position}]->{$field} = $widget->get_model->get( $widget->get_active_iter, 0 );
				} else {
					my $columntype = $widget->get_model->get_column_type(0);
					if ( $columntype eq "Glib::Int" ) {
						$self->{records}[$self->{slice_position}]->{$field} = 0;
					} else {
						$self->{records}[$self->{slice_position}]->{$field} = undef;
					}
				}
				
			} elsif ( $type eq "Gtk2::TextView" ) {
				
				my $textbuffer = $widget->get_buffer;
				my ( $start_iter, $end_iter ) = $textbuffer->get_bounds;
				$self->{records}[$self->{slice_position}]->{$field} = $textbuffer->get_text( $start_iter, $end_iter, 1 );
				
			} elsif ( $type eq "Gtk2::CheckButton" ) {
				
				if ( $widget->get_active ) {
					$self->{records}[$self->{slice_position}]->{$field} = 1;
				} else {
					$self->{records}[$self->{slice_position}]->{$field} = 0;
				}
				
			} else {
				
				$self->{records}[$self->{slice_position}]->{$field}=$self->{form}->get_widget($field)->get_text;
				
			}
		}
	}
	
	$self->{changed} = FALSE;
	
	# Execute external an_apply code
	if ($self->{on_apply}) {
		$self->{on_apply}();
	}
	
	return TRUE;
	
}

sub changed {
	
	# Sets the 'changed' flag, and update the RecordStatus indicator ( if there is one ).
	
	my $self = shift;
	
	if ( $self->{changelock} == FALSE ) {
		my $recordstatus = $self->{form}->get_widget("lbl_RecordStatus");
		if (defined $recordstatus) {
			$recordstatus->set_markup('<b><span color="red">Changed</span></b>');
		}
		$self->{changed} = TRUE;
		$self->paint_calculated;
	}
	
}

sub paint_calculated {
	
	# Paints calculated fields. If a field is passed, only that one gets calculated. Otherwise they all do.
	
	my ( $self, $field_to_paint ) = @_;
	
	foreach my $field ( $field_to_paint || keys %{$self->{calc_fields}} ) {
		my $widget = $self->{form}->get_widget($field);
		my $calc_value = eval $self->{calc_fields}->{$field};
		
		if (!defined $widget) {
			if ( ! $self->{quiet} ) {
				warn "*** Calculated Field $field is missing a widget! ***\n";
			}
		} else {
			if (ref $widget eq "Gtk2::Entry" || ref $widget eq "Gtk2::Label") {
				$self->{changelock} = TRUE;
				$widget->set_text($calc_value || 0);
				$self->{changelock} = FALSE;
			} else {
				warn "FIXME: Unknown widget type in Gtk2::Ex::DBI::paint_calculated: " . ref $widget . "\n";
			}
		}
	}
	
}

sub revert {
	
	# Reverts the form to the state of the in-memory recordset ( or deletes the in-memory record if we're adding a record )
	
	my $self = shift;
	
	if ( $self->{records}[$self->{slice_position}]->{$self->{primary_key}} eq "!" ) {
		# This looks like a new record. Delete it and roll back one record
		my $garbage_record = pop @{$self->{records}};
		$self->{changed} = FALSE;
		# Force a new slice to be fetched when we move(), which in turn deals with possible problems
		# if there are no records ( ie we want to put the insertion marker '!' back into the primary
		# key if there are no records )
		$self->{keyset_group} = -1;
		$self->move(-1);
	} else {
		# Existing record
		$self->{changed} = FALSE;
		$self->move(0);
	}
	
	$self->set_record_spinner_range;
	
}

sub undo {
	
	# undo is a synonym of revert
	
	my $self = shift;
	
	$self->revert;
	
}

sub delete {
	
	# Deletes the current record from the DB server and from memory
	
	my $self = shift;
	
	my $sth = $self->{dbh}->prepare("delete from " . $self->{sql}->{from} . " where " . $self->{primary_key} . "=?");
	
	eval {
		$sth->execute($self->{records}[$self->{slice_position}]->{$self->{primary_key}}) || die $self->{dbh}->errstr;
	};
	
	if ($@) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
								title	=> "Error Deleting Record!",
								text	=> "DB Server says:\n$@"
						       );
		$sth->finish;
		return FALSE;
	}
	
	$sth->finish;
	
	# Cancel any updates ( if the user changed something before pressing delete )
	$self->{changed} = FALSE;
	
	# First remove the record from the keyset
	splice(@{$self->{keyset}}, $self->position, 1);
	
	# Force a new slice to be fetched when we move(), which in turn handles with possible problems
	# if there are no records ( ie we want to put the insertion marker '!' back into the primary
	# key if there are no records )
	$self->{keyset_group} = -1;
	
	# Moving forwards will give problems if we're at the end of the keyset, so we move backwards instead
	# If we're already at the start, move() will deal with this gracefully
	$self->move(-1);
	
	$self->set_record_spinner_range;
	
}

sub position {
	
	# Returns the absolute position ( starting at 0 ) in the recordset ( taking into account the keyset and slice positions )
	
	my $self = shift;
	return ( $self->{keyset_group} * $self->{apeture} ) + $self->{slice_position};
	
}

sub set_record_spinner_range {
	
	# Convenience function that sets the min / max value of the record spinner
	
	my $self = shift;
	
	if ( $self->{spinner} ) {
		$self->{spinner}->signal_handler_block(		$self->{record_spinner_value_changed_signal} );
		$self->{spinner}->set_range( 1, $self->count );
		$self->{spinner}->signal_handler_unblock(	$self->{record_spinner_value_changed_signal} );
	}
	
	return TRUE;
	
}

sub set_active_iter_for_broken_combo_box {
	
	# This function is called when a ComboBoxEntry's value is changed
	# See http://bugzilla.gnome.org/show_bug.cgi?id=156017
	
	my ( $self, $widget ) = @_;
	
	my $string = $widget->get_child->get_text;
	my $model = $widget->get_model;
	my $current_iter = $widget->get_active_iter;
	my $iter = $model->get_iter_first;
	
	while ($iter) {
		if ( $string eq $model->get( $iter, 1 ) ) {
			$widget->set_active_iter($iter);
			if ( $iter != $current_iter ) {
				$self->changed;
			}
			last;
		}
		$iter = $model->iter_next($iter);
	}
	
	return FALSE; # Apparently we must return FALSE so the entry gets the event as well
	
}

sub last_insert_id {
	
	my $self = shift;
	
	my $sth = $self->{dbh}->prepare('select @@IDENTITY');
	$sth->execute;
	
	if (my $row = $sth->fetchrow_array) {
		$sth->finish;
		return $row;
	} else {
		$sth->finish;
		return undef;
	}
	
}

sub build_right_click_menu {
	
	# This sub appends menu items to the right-click menu of widgets
	
	# *** TODO *** Add some custom icons, particularly for the calculator ... find is OK
	
	my ( $self, $widget, $menu ) = @_;
	
	my $menu_item;
	
	# The 'find' menu item
	if ( ! $self->{disable_find} ) {
		$menu_item = Gtk2::ImageMenuItem->new_from_stock("gtk-find");
		$menu_item->signal_connect( activate => sub { $self->find_dialog($widget); } );
		$menu->append($menu_item);
		$menu_item->show;
	}
	
	# The 'calculator' menu item
	$menu_item = Gtk2::ImageMenuItem->new("Calculator");
	my $pixbuf = $widget->render_icon( "gtk-index", "menu" );
	my $image = Gtk2::Image->new_from_pixbuf($pixbuf);
	$menu_item->set_image($image);
	$menu_item->signal_connect( activate => sub { $self->calculator($widget); } );
	$menu->append($menu_item);
	$menu_item->show;
	
}

sub find_dialog {
	
	# Pops up a find dialog for the user to search the *existing* recordset
	my ( $self, $widget ) = @_;
		
	$self->{find}->{window} = Gtk2::Window->new ( "toplevel" );
	$self->{find}->{window}->set_title( "Gtk2::Ex::DBI advanced query" );
	$self->{find}->{window}->set_default_size( 300, 480 );
	$self->{find}->{window}->set_position( "center-always" );
	
	$self->{find}->{criteria_vbox} = Gtk2::VBox->new( 0, 5 );
	
	$self->{find}->{criteria} = ();
	
	# Construct a model to use for the 'operator' combo box in the criteria builder
	$self->{find}->{operator_model} = Gtk2::ListStore->new(
								"Glib::String",
								"Glib::String"
							      );
	
	foreach my $operator (
							[ "=",		"equals" ],
							[ "!=",		"does not equal" ],
							[ "<",		"less than" ],
							[ ">",		"greater than" ],
							[ "like",	"like" ]
			     )
	{
		$self->{find}->{operator_model}->set(
							$self->{find}->{operator_model}->append,
							0,		$$operator[0],
							1,		$$operator[1]
						    );
	}
	
	# Construct a model to use for the 'field' combo box in the criteria builder
	$self->{find}->{field_model} = Gtk2::ListStore->new( "Glib::String" );
	
	foreach my $field ( @{$self->{fieldlist}} ) {
		$self->{find}->{field_model}->set(
							$self->{find}->{field_model}->append,
							0,		$field
						 );
	}
	
	# Add a blank row ( and set the field of the first criteria row )
	$self->find_dialog_add_criteria( $widget->get_name );
	
	# A scrolled window to put the criteria selectors in
	my $sw = Gtk2::ScrolledWindow->new( undef, undef );
	$sw->set_shadow_type( "etched-in" );
	$sw->set_policy( "never", "always" );
	$sw->add_with_viewport( $self->{find}->{criteria_vbox} );
	
	# A button to add more criteria
	my $add_criteria_button = Gtk2::Button->new_from_stock( 'gtk-add' );
	$add_criteria_button->signal_connect( clicked	=> sub { $self->find_dialog_add_criteria } );
	
	# The find button
	my $find_button = Gtk2::Button->new_from_stock( 'gtk-find' );
	$find_button->signal_connect( clicked	=> sub { $self->find_do_search } );
	
	# An hbox to hold the buttons
	my $hbox = Gtk2::HBox->new( 0, 5 );
	$hbox->pack_start( $add_criteria_button, TRUE, TRUE, 5 );
	$hbox->pack_start( $find_button, TRUE, TRUE, 5 );
	
	# Another hbox to hold the headings
	my $headings_hbox = Gtk2::HBox->new( 0, 5 );
	
	# The headings
	my $field_heading = Gtk2::Label->new;
	$field_heading->set_markup( "<b>Field</b>" );
	
	my $operator_heading = Gtk2::Label->new;
	$operator_heading->set_markup( "<b>Operator</b>" );
	
	my $criteria_heading = Gtk2::Label->new;
	$criteria_heading->set_markup( "<b>Criteria</b>" );
	
	$headings_hbox->pack_start( $field_heading, TRUE, TRUE, 0 );
	$headings_hbox->pack_start( $operator_heading, TRUE, TRUE, 0 );
	$headings_hbox->pack_start( $criteria_heading, TRUE, TRUE, 0 );
	
	# Add everything to the dialog
	my $vbox = Gtk2::VBox->new( 0, 5 );
	
	my $title = Gtk2::Label->new;
	$title->set_markup( "<big><b>Enter criteria for the search ...</b></big>" );
	
	$vbox->pack_start( $title, FALSE, FALSE, 0 );
	$vbox->pack_start( $headings_hbox, FALSE, FALSE, 0 );
	$vbox->pack_start( $sw, TRUE, TRUE, 0 );
	$vbox->pack_start( $hbox, FALSE, FALSE, 0 );
	
	$self->{find}->{window}->add( $vbox );
	
	# Show everything
	$self->{find}->{window}->show_all;
	
}

sub find_do_search {
	
	my $self = shift;
	
	my ( $where_clause, $bind_values );
	
	# Limit to current recordset?
	if ( $self->{disable_full_table_find} ) {
		$where_clause = $self->{sql}->{where};
		$bind_values = $self->{sql}->{bind_values};
	}
	
	# Loop through criteria array and assemble where clause
	for my $criteria ( @{$self->{find}->{criteria}} ) {
		
		my $operator;
		my $iter = $criteria->{operator_combo}->get_active_iter;
		
		if ( $iter ) {
			
			$operator = $criteria->{operator_combo}->get_model->get( $iter, 0 );
			
			if ( $where_clause ) {
				$where_clause .= " and ";
			}
			
			$where_clause .= $criteria->{field_combo}->get_child->get_text
				. " " . $operator . " " . "?";
			
			# We need to put wildcards around a 'like' search
			if ( $operator eq "like" ) {
				push @{$bind_values}, "%" . $criteria->{criteria_entry}->get_text . "%";
			} else {
				push @{$bind_values}, $criteria->{criteria_entry}->get_text;
			}
			
		}
		
	}
	
	$self->query(
			{
				where		=> $where_clause,
				bind_values	=> $bind_values
			}
		    );
	
	$self->{find}->{window}->destroy;
	
}

sub find_dialog_add_criteria {
	
	# Creates a new row of widgets for more criteria for our search operation, and store them
	# in an array ( $self->{find}->{criteria} )
	
	my ( $self, $widget ) = @_;
	
	# Create 3 widgets for the row
	my $field_combo = Gtk2::ComboBoxEntry->new( $self->{find}->{field_model}, 0 );
	my $operator_combo = Gtk2::ComboBoxEntry->new( $self->{find}->{operator_model}, 1 );
	my $criteria_entry = Gtk2::Entry->new;
	
	# Set the field if we've been passed one
	if ( $widget ) {
		$field_combo->get_child->set_text( $widget );
	}
	
	# Create an hbox to hold the 3 widgets
	my $hbox = Gtk2::HBox->new( TRUE, 5 );
	
	# Put widgets into hbox
	$hbox->pack_start( $field_combo,	TRUE, TRUE, 5 );
	$hbox->pack_start( $operator_combo,	TRUE, TRUE, 5 );
	$hbox->pack_start( $criteria_entry,	TRUE, TRUE, 5 );
	
	# Make a hash of the current criteria widgets
	my $new_criteria = {
				field_combo	=> $field_combo,
				operator_combo	=> $operator_combo,
				criteria_entry	=> $criteria_entry
			   };
	
	# Append this hash onto our list of all criteria widgets
	push @{$self->{find}->{criteria}}, $new_criteria;
	
	# Add the hbox to the main vbox
	$self->{find}->{criteria_vbox}->pack_start( $hbox, FALSE, FALSE, 5 );
	
	# Show them
	$hbox->show_all;
	
}

sub calculator {
	
	# This pops up a simple addition-only calculator, and returns the calculated value to the calling widget
	
	my ( $self, $widget ) = @_;
	
	my $dialog = Gtk2::Dialog->new (
						"Gtk2::Ex::DBI calculator",
						undef,
						"modal",
						"gtk-ok"	=> "ok",
						"gtk-cancel"	=> "reject"
				       );
	
	$dialog->set_default_size( 300, 480 );
	
	# The model
	my $model = Gtk2::ListStore->new( "Glib::Double" );
	
	# Add an initial row data to the model
	my $iter = $model->append;
	$model->set( $iter, 0, 0 );
	
	# A renderer
	my $renderer = Gtk2::CellRendererText->new;
	$renderer->set( editable => TRUE );
	
	# A column
	my $column = Gtk2::TreeViewColumn->new_with_attributes(
								"Values",
								$renderer,
								'text'	=> 0
							      );
	
	# The TreeView
	my $treeview = Gtk2::TreeView->new( $model );
	$treeview->set_rules_hint( TRUE );
	$treeview->append_column($column);
	
	# A scrolled window to put the TreeView in
	my $sw = Gtk2::ScrolledWindow->new( undef, undef );
	$sw->set_shadow_type( "etched-in" );
	$sw->set_policy( "never", "always" );
	
	# Add treeview to scrolled window
	$sw->add( $treeview );
	
	# Add scrolled window to the dialog
	$dialog->vbox->pack_start( $sw, TRUE, TRUE, 0 );
	
	# Add a Gtk2::Entry to show the current total
	my $total_widget = Gtk2::Entry->new;
	$dialog->vbox->pack_start( $total_widget, FALSE, FALSE, 0 );
	
	# Handle editing in the renderer
	$renderer->signal_connect( edited => sub {
		$self->calculator_process_editing( @_, $treeview, $model, $column, $total_widget );
	} );
	
	# Show everything
	$dialog->show_all;
	
	# Start editing in the 1st row
	$treeview->set_cursor( $model->get_path( $iter ), $column, TRUE );
	
	my $response = $dialog->run;
	
	if ( $response eq "ok" ) {
		# Transfer value back to calling widget and exit
		$widget->set_text( $total_widget->get_text );
		$dialog->destroy;
	} else {
		$dialog->destroy;
	}
	
}

sub calculator_process_editing {
	
	my ( $self, $renderer, $text_path, $new_text, $treeview, $model, $column, $total_widget ) = @_;
	
	my $path = Gtk2::TreePath->new_from_string ($text_path);
	my $iter = $model->get_iter ($path);
	
	# Only do something if we get a numeric value that isn't zero
	if ( $new_text !~ /\d/ || $new_text == 0 ) {
		return FALSE;
	}
	
	$model->set( $iter, 0, $new_text);
	my $new_iter = $model->append;
	
	$treeview->set_cursor(
				$model->get_path( $new_iter ),
				$column,
				TRUE
			     );
	
	# Calculate total and display
	$iter = $model->get_iter_first;
	my $current_total;
	
	while ( $iter ) {
				$current_total += $model->get( $iter, 0 );
				$iter = $model->iter_next( $iter );
	}
	
	$total_widget->set_text( $current_total );
	
}

1;

=head1 NAME

Gtk2::Ex::DBI - Bind a Gtk2::GladeXML - generated window to a DBI data source

=head1 SYNOPSIS

use DBI;
use Gtk2 -init;
use Gtk2::GladeXML;
use Gtk2::Ex::DBI; 

my $dbh = DBI->connect (
                          "dbi:mysql:dbname=sales;host=screamer;port=3306",
                          "some_username",
                          "salespass", {
                                           PrintError => 0,
                                           RaiseError => 0,
                                           AutoCommit => 1,
                                       }
);

my $prospects_form = Gtk2::GladeXML->new("/path/to/glade/file/my_form.glade", 'Prospects');

my $data_handler = Gtk2::Ex::DBI->new( {
            dbh         => $dbh,
            schema      => "sales",
            sql         => {
                              select       => "*",
                              from         => "Prospects",
                              where        => "Actve=? and Employees>?",
                              where_values => \[ 1, 200 ],
                              order_by     => "ClientName",
                           },
            form        => $prospects,
            formname    => "Prospects",
            on_current  => \&Prospects_current,
            calc_fields =>
            {
                        calc_total => 'eval { $self->{form}->get_widget("value_1")->get_text
                            + $self->{form}->get_widget("value_2")->get_text }'
            },
            default_values     =>
            {
                        ContractYears  => 5,
                        Fee            => 2000
            }
}
);

sub Prospects_current {

            # I get called when moving from one record to another ( see on_current key, above )

}

=head1 DESCRIPTION

This module automates the process of tying data from a DBI datasource to widgets on a Glade-generated form.
All that is required is that you name your widgets the same as the fields in your data source.
You have to set up combo boxes ( ie create your Gtk2::ListStore and
attach it to your combo box ) *before* creating your Gtk2::Ex::DBI object.

Steps for use:

* Open a DBI connection

* Create a Gtk2::GladeXML object ( form )

* Create a Gtk2::Ex::DBI object and link it to your form

You would then typically create some buttons and connect them to the methods below to handle common actions
such as inserting, moving, deleting, etc.

=head1 METHODS

=head2 new

=over 4

Object constructor. Expects a hash of key / value pairs. Bare minimum are:

=head3 dbh

=over 4

a DBI database handle

=back

=head3 form

=over 4

the Gtk2::GladeXML object that created your form

=back

=head3 formname

=over 4

the name of the form ( from the Glade file )

=back

=head3 sql

=over 4

The sql object describes the query to be executed to fetch your records. Note that in contrast to
version 1.x, all the keywords ( select, from, where, order by, etc ) are *OMMITTED* ... see above
example. This is for consistency and ease of manipulating things. Trust me.

Minimum requirements for the sql object are the 'select' and 'from' keys. All others are optional.

Details:

=over 4

=head3 select

=over 4

The SELECT clause

=back

=head3 from

=over 4

The FROM clause

=back

=head3 where

=over 4

The WHERE clause ( try '0=1' for inserting records )

=back

=head3 bind_values

=over 4

An array of values to bind to placeholders ... you ARE using placeholders, right?

=back

=head3 order_by

=over 4

The ORDER BY clause

=back

=back

=back

Other ( non-essential ) keys:

=head3 primary_key

=over 4

The PRIMARY KEY of the table you are querying.

As of version 2.0, the primary key is automatically selected for you if you use MySQL. Note, however,
that this will only work if the FROM clause contains a single table. If you have a multi-table query,
you must specify the primary_key, otherwise the last primary_key encountered will use. I recommend
against using multi-table queries anyway.

=back

=head3 on_current

=over 4

A reference to some Perl code to run when moving to a new record

=back

=head3 on_apply

=over 4

A reference to some Perl code to tun *after* applying the current record

=back

=head3 calc_fields

=over 4

A hash of fieldnames / Perl expressions to provide calculated fields

=back

=head3 apeture

=over 4

The size of the recordset slice ( in records ) to fetch into memory
ONLY change this BEFORE querying

=back

=head3 manual_spinner

=over 4

Disable automatic move() operations when the RecordSpinner is clicked

=back

=head3 read_only

=over 4

Whether we allow updates to the recordset ( default = FALSE ; updates allowed )

=back

=head3 defaults

=over 4

A HOH of default values to use when a new record is inserted

=back

=head3 quiet

=over 4

A flag to silence warnings such as missing widgets

=back

=head3 schema

=over 4

The schema to query to get field details ( defaults, column types ) ... not required for MySQL

=back

=head3 disable_full_table_find

=over 4

Don't allow the user to replace the where clause; only append to the existing one

=back

=head3 disable_find

=over 4

Disable the 'find' item in the right-click menu of GtkText widgets ( ie disable user-initiated searches )

=back

The 'new' method will call the 'query' method, which will in turn move to the 1st record and paint your form.

=back

=head2 fieldlist

=over 4

Returns a fieldlist as an array, based on the current query.
Mainly for internal Gtk2::Ex::DBI use

=back

=head2 query ( [ where_object ] )

=over 4

Requeries the DB server, either with the current where clause, or with a new one ( if passed ).

Version 2.x expects a where_object hash, containing the following keys:

=head3 where

=over 4

The where key should contain the where clause, with placeholders ( ? ) for each value.
Using placeholders is particularly important if you're assembling a query based on
values taken from a form, as users can initiate an SQL injection attack if you
insert values directly into your where clause.

=back

=head3 bind_values

=over 4

bind_values should be an array of values, one for each placeholder in your where clause.

=back

Version 1.x expected to be passed an optional string as a new where clause.
This behaviour is still supported for backwards compatibility. If a version 1.x call
is detected ( ie if where_object isn't a hash ), any existing bind_values will be deleted

=back

=head2 insert

=over 4

Inserts a new record in the *in-memory* recordset and sets up default values,
either from the database schema, or optionally overridden with values from the
default_values hash.

=back

=head2 count

=over 4

Returns the number of records in the current recordset.

=back

=head2 paint

=over 4

Paints the form with current data. Mainly for internal Gtk2::Ex::DBI use.

=back

=head2 move ( offset, [ absolute_position ] )

=over 4

Moves to a specified position in the recordset - either an offset, or an absolute position.
If an absolute position is given, the offset is ignored.
If there are changes to the current record, these are applied to the DB server first.
Returns TRUE if successful, FALSE if unsuccessful.

=back

=head2 apply

=over 4

Apply changes to the current record back to the DB server.
Returns TRUE if successful, FALSE if unsuccessful.

=back

=head2 changed

=over 4

Sets the 'changed' flag, which is used internally when deciding if an 'apply' is required.

=back

=head2 revert

=over 4

Reverts the current record back to its original state.
Deletes the in-memory recordset if we were inserting a new record.

=back

=head2 delete

=over 4

Deletes the current record. Asks for confirmation first.
If you are selecting from multiple tables, this method will not work as
expected, if at all, as we don't know which table you want to delete from. The best case
scenario is an error - this is what MySQL does. Other database may delete from both / all
tables. I haven't tried this, but I wouldn't be surprised ...

=back

=head2 find_dialog ( [ field ] )

=over 4

Opens a find 'dialog' ( a window in GTK speak ) that allows the user to query the active
table ( whatever's in the sql->{from} clause ). This will allow them to *alter* the where
clause. If you only want them to be able to *append* to the existing where clause, then
set the disable_full_table_find key to TRUE ( see 'new' method ).

If an optional field is passed, this will be inserted into the dialog as the first field
in the criteria list.

Note that the user can currently activate the find_dialog by right-clicking in a text field.
To disable this behaviour, set the disable_find key to TRUE ( see 'new' method ).

=back

=head2 position

=over 4

Returns the current position in the keyset ( starting at zero ).

=back

=head1 ISSUES

=head2 SQL Server support is *UNSTABLE*

Previously I had claimed that this module had been tested under SQL Server.
Now, unfortunately, I have to report that there are some bugs *somewhere* in the chain
from DBD::ODBC to FreeTDS. In particular, 'money' column types in SQL Server will not
work at all - SQL Server throws a type conversion error. Also I have had very strange results
with 'decimal' column types - the 1st couple of fields are accepted, and everything after that
ends up NULL. When I encountered this, I added the 'debug' flag to this module to dump details
of the values being pulled from widgets and placed into our @bind_variables array. Rest assured
that everything *here* is working fine. The problem is certainly somewhere further up the chain.
So be warned - while some forms work quite well with SQL Server, others will *NOT*. Test first.
Better still, don't use SQL Server.

=head1 AUTHORS

Daniel Kasak - dan@entropy.homelinux.org

=head1 CREDITS

Muppet

 - tirelessly offered help and suggestions in response to my endless list of questions

Gtk2-Perl Authors

 - obviously without them, I wouldn't have gotten very far ...

Gtk2-Perl list

 - yet more help, suggestions, and general words of encouragement

=head1 Other cool things you should know about:

This module is part of an umbrella project, 'Axis Not Evil', which aims to make
Rapid Application Development of database apps using open-source tools a reality.
The project includes:

  Gtk2::Ex::DBI                 - forms
  Gtk2::Ex::Datasheet::DBI      - datasheets
  PDF::ReportWriter             - reports

All the above modules are available via cpan, or for more information, screenshots, etc, see:
http://entropy.homelinux.org/axis_not_evil

=head1 Crank ON!

=cut