#!/usr/bin/perl

# (C) Daniel Kasak: dan@entropy.homelinux.org
# See COPYRIGHT file for full license

# See 'man Gtk2::Ex::DBI' for full documentation ... or of course continue reading

package Gtk2::Ex::DBI;

use strict;
use warnings;

use DBI;
use POSIX;

use Glib qw/TRUE FALSE/;

use Gtk2::Ex::Dialogs (
			destroy_with_parent	=> TRUE,
			modal			=> TRUE,
			no_separator		=> FALSE
		      );

BEGIN {
	$Gtk2::Ex::DBI::VERSION = '1.1';
}

sub new {
	
	my ( $class, $req ) = @_;
	
	# Assemble object from request
	my $self = {
			dbh			=> $$req{dbh},			# A database handle
			table			=> $$req{table},		# The source table
			primarykey		=> $$req{primarykey},		# The primary key ( needed for inserts / updates )
			sql_select		=> $$req{sql_select},		# The 'select' clause of the query
			sql_where		=> $$req{sql_where},		# The 'where' clause of the query
			sql_order_by		=> $$req{sql_order_by},		# The 'order by' clause of the query
			form			=> $$req{form},			# The Gtk2-GladeXML *object* we're using
			formname		=> $$req{formname},		# The *name* of the window ( needed for dialogs to work properly )
			readonly		=> $$req{readonly} || 0,	# Whether changes to the table are allowed
			apeture			=> $$req{apeture} || 100,	# The number of records to select at a time
			on_current		=> $$req{on_current},		# A reference to code that is run when we move to a new record
			on_apply		=> $$req{on_apply},		# A reference to code that is run *after* the 'apply' method is called
			calc_fields		=> $$req{calc_fields},		# Calculated field definitions ( HOH )
			defaults		=> $$req{defaults},		# Default values ( HOH )
			quiet			=> $$req{quiet} || 0,		# A flag to silence warnings such as missing widgets
			changed			=> 0,				# A flag indicating that the current record has been changed
			changelock		=> 0,				# Prevents the 'changed' flag from being set when we're moving records
			constructor_done	=> 0,				# A flag that indicates whether the new() method has completed yet
			debug			=> $$req{debug} || 0		# Turn on to dump info to terminal
	};
	
	bless $self, $class;
	
	# Cache the fieldlist array so we don't have to continually query the DB server for it
	my $sth = $self->{dbh}->prepare($self->{sql_select} . " from " . $self->{table} . " where 0=1");
	$sth->execute;
	$self->{fieldlist} = $sth->{'NAME'};
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
	
	foreach my $field ( @{$self->{fieldlist}} ) {
		my $widget = $self->{form}->get_widget($field);
		if (defined $widget) {
			my $type = (ref $widget);
			if ($type eq "Gtk2::Calendar") {
				$widget->signal_connect(		day_selected	=> sub { $self->changed; } );
			} elsif ($type eq "Gtk2::ToggleButton") {
				$widget->signal_connect(		toggled		=> sub { $self->changed; } );
			} elsif ($type eq "Gtk2::TextView") {
				$widget->get_buffer->signal_connect(	changed		=> sub { $self->changed; } );
			} elsif ($type eq "Gtk2::ComboBoxEntry") {
				$widget->signal_connect(		changed		=> sub { $self->changed; } );
				$widget->get_child->signal_connect(	changed		=> sub { $self->set_active_iter_for_broken_combo_box($widget) } );
			} elsif ($type eq "Gtk2::CheckButton") {
				$widget->signal_connect(		toggled		=> sub { $self->changed; } );
			} elsif ($type eq "Gtk2::Entry") {
				$widget->signal_connect(		changed		=> sub { $self->changed; } );
				# *** TODO *** enable this when we've added search functionality
				$widget->signal_connect(		'populate-popup'=> sub { $self->build_right_click_menu(@_); } );
			} else {
				$widget->signal_connect(		changed		=> sub { $self->changed; } );
			}
		}
	}
	
	$self->{spinner} = $self->{form}->get_widget("RecordSpinner");
	
	if ( $self->{spinner} ) {
		
		$self->{record_spinner_value_changed_signal}
			= $self->{spinner}->signal_connect( value_changed	=> sub {
				$self->{spinner}->signal_handler_block($self->{record_spinner_value_changed_signal});
				$self->move( undef, $self->{spinner}->get_text - 1 );
				$self->{spinner}->signal_handler_unblock($self->{record_spinner_value_changed_signal});
				return 1;
			}
						 );
	}
	
	$self->{constructor_done} = 1;
	
	$self->set_record_spinner_range;
	
	return $self;
	
}

sub fieldlist {
	
	# Provide legacy fieldlist method
	
	my $self = shift;
	
	return $self->{fieldlist};
	
}

sub query {
	
	my ( $self, $sql_where ) = @_;
	
	# Update database from current hash if necessary
	if ($self->{changed} == 1) {
		
		my $answer = ask Gtk2::Ex::Dialogs::Question(
				    title	=> "Apply changes to " . $self->{table} . " before querying?",
				    text	=> "There are outstanding changes to the current record ( " . $self->{table} . " )."
							. " Do you want to apply them before running a new query?"
							    );

		if ($answer) {
		    if ( ! $self->apply ) {
			return FALSE; # Apply method will already give a dialog explaining error
		    }
		}
		
	}
	
	if (defined $sql_where) {
		$self->{sql_where} = $sql_where;
	}
	
	$self->{keyset_group} = undef;
	$self->{slice_position} = undef;
	
	# Get an array of primary keys
	my $sth = $self->{dbh}->prepare(
		"select " . $self->{primarykey}
		. " from " . $self->{table} . " "
		. $self->{sql_where} || "" . " "
		. $self->{sql_order_by} || ""
				       );
	
	$sth->execute;
	
	$self->{keyset} = ();
	
	while (my @row = $sth->fetchrow_array) {
		push @{$self->{keyset}}, $row[0];
	}
	
	$sth->finish;
	
	if ( $self->{spinner} ) {
		$self->{spinner}->signal_handler_block(		$self->{record_spinner_value_changed_signal} );
		$self->set_record_spinner_range;
		$self->{spinner}->signal_handler_unblock(	$self->{record_spinner_value_changed_signal} );
	}
	
	$self->move(0, 0);
	
	$self->set_record_spinner_range;
	
	return 1;
	
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
	
	if (! $self->move(0, $newposition)) {
		warn "Insert failed ... probably because the current record couldn't be applied\n";
		return 0;
	}
	
	$self->{records}[$self->{slice_position}]->{$self->{primarykey}} = "!";
	$self->set_defaults;
	$self->paint; # 2nd time this is called in this sub ( 1st from $self->move ) but we need to do it again to paint the default values
	
	return 1;
	
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
	$self->{changelock} = 1;
	
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
						( $self->{records}[$self->{slice_position}]->{$field} eq $widget->get_model->get($iter, 0)) ) {
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
	$self->{changelock} = 0;
	
}

sub move {
	
	# Moves to the requested position, either as an offset from the current position,
	# or as an absolute value. If an absolute value is given, it overrides the offset.
	# If there are changes to the current record, these are applied to the DB server first.
	# Returns 1 if successful, 0 if unsuccessful.
	
	my ( $self, $offset, $absolute ) = @_;
	
	# Update database from current hash if necessary
	if ($self->{changed} == 1) {
		my $result = $self->apply;
		if ($result == 0) {
			# Update failed. If RecordSpinner exists, set it to the current position PLUS ONE.
			if ( $self->{spinner} ) {
				$self->{spinner}->signal_handler_block(		$self->{record_spinner_value_changed_signal});
				$self->{spinner}->set_text( $self->position + 1 );
				$self->{spinner}->signal_handler_block(		$self->{record_spinner_value_changed_signal});
			}
			return 0;
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
		if ($new_position < 0) {
			$new_position = $self->count - 1;
		} elsif ($new_position > $self->count - 1) {
			$new_position = 0;
		}
	}
	
	# Check if we now have a sane $new_position.
	# Some operations ( insert, then revert part-way through ... or move backwards when there are no records ) can cause this.
	if ($new_position < 0) {
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
	
	return 1;
	
}

sub fetch_new_slice {
	
	# Fetches a new 'slice' of records ( based on the aperture size )
	
	my $self = shift;
	
	# Get max value for the loop ( not sure if putting a calculation inside the loop def slows it down or not )
	my $lower = $self->{keyset_group} * $self->{apeture};
	my $upper = ( ($self->{keyset_group} + 1) * $self->{apeture} ) - 1;
	
	# Don't try to fetch records that aren't there ( at the end of the recordset )
	my $keyset_count = $self->count; # So we don't keep running $self->count...
	
	if ($keyset_count == 0) {
		
		# This ( keyset_count == 0 ) will happen if we have an empty recordset in our keyset
		# ( ie if there are no records returned ). Create an empty array. 
		$self->{records} = ();
		
		# In this case, we should also set the insertion flag, in case people want to start typing
		# straight into the form. After all, the fields will all be blank, so people will not feel
		# the need to hit the 'insert' button.
		# Note that we *don't* set the changed flag, as the user may *not* insert anything at this point
		
		$self->{records}[$self->{slice_position}]->{$self->{primarykey}} = "!";
		$self->set_defaults; # Paint will happen back in the move() operation
		
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
		
		# Check we have a primary key ( or a wildcard ) in sql_select; append primary key if we don't - we need it
		if ( $self->{sql_select} !~ /$self->{primarykey}/ && $self->{sql_select} !~ /[\*|%]/ ) {
			$self->{sql_select} .= ", " . $self->{primarykey};
		}
		
		$self->{records} = $self->{dbh}->selectall_arrayref (
			$self->{sql_select}
			. " from " . $self->{table}
			. " where " . $self->{primarykey} . " in ($key_list )",
			{Slice=>{}}					    )
			|| die "Error in SQL:\n" . $self->{sql_select} . " from " . $self->{table} . " where " . $self->{primarykey} . " in ($key_list )\n";
		
	}
	
}

sub apply {
	
	# Applys the data from the current form back to the DB server.
	# Returns 1 if successful, 0 if unsuccessful.
	
	my $self = shift;
	
	if ($self->{readonly} == 1) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
							title	=> "Read Only!",
							text	=> "Sorry. This form is open\nin read-only mode!"
						       );
		return 0;
	}
	
	my $fieldlist = "";
	my @bind_values = ();
	
	my $inserting = 0; # Flag that tells us whether we're inserting or updating
	my $placeholders;  # We need to append to the placeholders while we're looping through fields, so we know how many fields we actually have
	
	if ($self->{records}[$self->{slice_position}]->{$self->{primarykey}} eq "!") {
		$inserting = 1;
	}
	
	foreach my $field ( @{$self->{fieldlist}} ) {
		
		if ( $self->{debug} ) {
			print "Processing field $field ...\n";
		}
		
		my $current_value = undef;
		
		my $widget = $self->{form}->get_widget($field);
		
		if (defined $widget) {
			
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
			
			if ($type eq "Gtk2::Calendar") {
				
				my ( $year, $month, $day ) = $widget->get_date;
				my $date;
				
				if ($day > 0) {
					
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
				
				
			} elsif ($type eq "Gtk2::ToggleButton") {
				
				if ($widget->get_active) {
					$current_value = 1;
				} else {
					$current_value = 0;
				}
				
			} elsif ($type eq "Gtk2::ComboBoxEntry") {   
				
				my $iter = $widget->get_active_iter;                
				
				# If $iter is defined ( ie something is selected ), push the ID of the selected row
				# onto @bind_values,  otherwise test the column type.
				# If we find a "Glib::Int" column type, we push a zero onto @bind_values otherwise 'undef'
				
				if (defined $iter) {
					$current_value = $widget->get_model->get($iter, 0);
				} else {                    
					my $columntype = $widget->get_model->get_column_type(0);                    
					if ($columntype eq "Glib::Int") {
						$current_value = 0;
					} else {
						$current_value = undef;
					}
				}
				
			} elsif ($type eq "Gtk2::TextView") {
				
				my $textbuffer = $widget->get_buffer;
				my ( $start_iter, $end_iter ) = $textbuffer->get_bounds;
				$current_value = $textbuffer->get_text($start_iter, $end_iter, 1);
				
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
		$update_sql = "insert into " .$self->{table} . " ( $fieldlist ) values ( $placeholders )";
	} else {
		push @bind_values, $self->{records}[$self->{slice_position}]->{$self->{primarykey}};
		$update_sql = "update " . $self->{table} . " set $fieldlist where " . $self->{primarykey} . "=?";
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
									text    => "Database Server says:\n" . $self->{dbh}->errstr
							       );
			warn "Error updating recordset:\n$update_sql\n@bind_values\n" . $@ . "\n\n";
			return 0;
	}
	
	my $recordstatus = $self->{form}->get_widget("lbl_RecordStatus");
	
	if (defined $recordstatus) {
		$recordstatus->set_markup('<b>Synchronized</b>');
	}
	
	# If this was an INSERT, we need to fetch the primary key value and apply it to the local slice, and also append the primary key to the keyset
	if ($inserting) {
		
		my $inserted_id = $self->last_insert_id;
		
		$self->{records}[$self->{slice_position}]->{$self->{primarykey}} = $inserted_id;
		push @{$self->{keyset}}, $inserted_id;
		
		# Apply primary key to form ( if field exists )
		my $widget = $self->{form}->get_widget($self->{primarykey});
		
		if ($widget) {
			$widget->set_text($inserted_id); # Assuming the widget has a set_text method of course ... can't see when this wouldn't be the case
		}
		
		$widget->signal_handler_block(		$self->{record_spinner_value_changed_signal} );
		$self->set_record_spinner_range;
		$widget->signal_handler_unblock(	$self->{record_spinner_value_changed_signal} );
		
	}
	
	# SQL update successfull. Now apply update to local array. Comments ommitted, but logic is the same as above.
	
	foreach my $field ( @{$self->{fieldlist}} ) {
		
		my $widget = $self->{form}->get_widget($field);
		
		if (defined $widget) {
			
			my $type = (ref $widget);
			
			if ($type eq "Gtk2::Calendar") {
				
				my ( $year, $month, $day ) = $widget->get_date;
				my $date;
				
				if ($day > 0) {
					$month ++;
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
				
				$self->{records}[$self->{slice_position}]->{$field}=$date;
				
			} elsif ($type eq "Gtk2::ToggleButton") {
				
				if ($widget->get_active) {
					$self->{records}[$self->{slice_position}]->{$field} = 1;
				} else {
					$self->{records}[$self->{slice_position}]->{$field} = 0;
				}
				
			} elsif ($type eq "Gtk2::ComboBoxEntry") {
				
				my $iter = $widget->get_active_iter;
				
				if (defined $iter) {
					$self->{records}[$self->{slice_position}]->{$field} = $widget->get_model->get($widget->get_active_iter, 0);
				} else {
					my $columntype = $widget->get_model->get_column_type(0);
					if ($columntype eq "Glib::Int") {
						$self->{records}[$self->{slice_position}]->{$field} = 0;
					} else {
						$self->{records}[$self->{slice_position}]->{$field} = undef;
					}
				}
				
			} elsif ($type eq "Gtk2::TextView") {
				
				my $textbuffer = $widget->get_buffer;
				my ( $start_iter, $end_iter ) = $textbuffer->get_bounds;
				$self->{records}[$self->{slice_position}]->{$field} = $textbuffer->get_text($start_iter, $end_iter, 1);
				
			} elsif ($type eq "Gtk2::CheckButton") {
				
				if ($widget->get_active) {
					$self->{records}[$self->{slice_position}]->{$field} = 1;
				} else {
					$self->{records}[$self->{slice_position}]->{$field} = 0;
				}
				
			} else {
				
				$self->{records}[$self->{slice_position}]->{$field}=$self->{form}->get_widget($field)->get_text;
				
			}
		}
	}
	
	$self->{changed} = 0;
	
	# Execute external an_apply code
	if ($self->{on_apply}) {
		$self->{on_apply}();
	}
	
	return 1;
	
}

sub changed {
	
	# Sets the 'changed' flag, and update the RecordStatus indicator ( if there is one ).
	
	my $self = shift;
	
	if ($self->{changelock} == 0) {
		my $recordstatus = $self->{form}->get_widget("lbl_RecordStatus");
		if (defined $recordstatus) {
			$recordstatus->set_markup('<b><span color="red">Changed</span></b>');
		}
		$self->{changed} = 1;
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
				$self->{changelock} = 1;
				$widget->set_text($calc_value || "");
				$self->{changelock} = 0;
			} else {
				warn "FIXME: Unknown widget type in Gtk2::Ex::DBI::paint_calculated: " . ref $widget . "\n";
			}
		}
	}
	
}

sub revert {
	
	# Reverts the form to the state of the in-memory recordset ( or deletes the in-memory record if we're adding a record )
	
	my $self = shift;
	
	if ($self->{records}[$self->{slice_position}]->{$self->{primarykey}} eq "!") {
		# This looks like a new record. Delete it and roll back one record
		my $garbage_record = pop @{$self->{records}};
		$self->{changed} = 0;
		# Force a new slice to be fetched when we move(), which in turn handles with possible problems
		# if there are no records ( ie we want to put the insertion marker '!' back into the primary
		# key if there are no records )
		$self->{keyset_group} = -1;
		$self->move(-1);
	} else {
		# Existing record
		$self->{changed} = 0;
		$self->move(0);
	}
	
	$self->set_record_spinner_range;
	
}

sub delete {
	
	# Deletes the current record from the DB server and from memory
	
	my $self = shift;
	
	my $sth = $self->{dbh}->prepare("delete from " . $self->{table} . " where " . $self->{primarykey} . "=?");
	
	eval {
		$sth->execute($self->{records}[$self->{slice_position}]->{$self->{primarykey}}) || die $self->{dbh}->errstr;
	};
	
	$sth->finish;
	
	if ($@) {
		new_and_run Gtk2::Ex::Dialogs::ErrorMsg(
								title	=> "Error Deleting Record!",
								text	=> "DB Server says:\n$@"
						       );
		return 0;
	}
	
	# Cancel any updates ( if the user changed something before pressing delete )
	$self->{changed} = 0;
	
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
		$self->{spinner}->set_range(1, $self->count);
		$self->{spinner}->signal_handler_unblock(	$self->{record_spinner_value_changed_signal} );
	}
	
	return 1;
	
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
		if ($string eq $model->get($iter, 1)) {
			$widget->set_active_iter($iter);
			if ($iter != $current_iter) {
				$self->changed;
			}
			last;
		}
		$iter = $model->iter_next($iter);
	}
	
	return 0; # Apparently we must return FALSE so the entry get the event as well
	
}

sub set_defaults {
	
	# Sets default values for fields ( called when a new record is inserted )
	
	my $self = shift;
	
	foreach my $field ( keys %{$self->{defaults}} ) {		
		$self->{records}[$self->{slice_position}]->{$field} = $self->{defaults}->{$field};
	}
	
	return 1;
	
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

# *** These last 2 subs are not really functional yet. I started on a 'simple' search, activated from
# *** individual fields, and then thought it might be a better idea to do a nice advanced search
# *** dialog. I've left this in place for now in case I want to hook up this 'simple' functionality
# *** to a more advanced dialog ... if I implement a more advanced dialog of course.

sub build_right_click_menu {
	
	# This sub appends menu items to the right-click menu of widgets ( currently only Gtk2::Entry widgets )
	
	# *** TODO *** Add some custom icons, particularly for the calculator ... find is OK
	
	my ( $self, $widget, $menu ) = @_;
	
	# The 'find' menu item
	my $menu_item = Gtk2::ImageMenuItem->new_from_stock("gtk-find");
	$menu_item->signal_connect( activate => sub { $self->find_dialog($widget); } );
	$menu->append($menu_item);
	$menu_item->show;
	
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
	print "\nGtk2::Ex::DBI - User has selected 'find' from a Gtk2::Entry ...\n ... ( functionality not yet added - see TODO )\n\n";
	
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

Gtk2::Ex::DBI

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
            table       => "Prospects",
            primarykey  => "LeadNo",
            sql_select  => "select *",
            sql_where   => "where Actve=1",
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

Object constructor. Expects a hash of key / value pairs. Bare minimum are:

dbh             - a DBI database handle
table           - the name of the table you are querying
primary_key     - the primary key of the table you are querying ( required for updating / deleting )
sql_select      - the 'select' clause of the query
form            - the Gtk2::GladeXML object that created your form
formname        - the name of the form ( from the Glade file )

The 'new' method will call the 'query' method, which will in turn move to the 1st record and paint your form.

Other keys:

sql_where       - the 'where' clause of the query
                    ( try 'where 0=1' for economy when you are simply inserting records )

on_current      - a reference to some Perl code to run when moving to a new record

on_apply        - a reference to some Perl code to tun *after* applying the current record

calc_fields     - a hash of fieldnames / Perl expressions to provide calculated fields

sql_order_by    - the 'order by' clause of the query

apeture         - the size of the recordset slice ( in records ) to fetch into memory
                                 ONLY change this BEFORE querying

manual_spinner  - disable automatic move() operations when the RecordSpinner is clicked
read_only       - whether we allow updates to the recordset ( default = 0 ; updates allowed )
defaults        - a HOH of default values to use when a new record is inserted
quiet           - a flag to silence warnings such as missing widgets

=head2 fieldlist

Returns a fieldlist as an array, based on the current query.
Mainly for internal Gtk2::Ex::DBI use

=head2 query ( [ new_where_clause ] )
Requeries the DB server, either with the current where clause, or with a new one ( if passed ).

=head2 insert
Inserts a new record in the *in-memory* recordset and sets up default values ( if defined ).

=head2 count
Returns the number of records in the current recordset.

=head2 paint
Paints the form with current data. Mainly for internal Gtk2::Ex::DBI use.

=head2 move ( offset, [ absolute_position ] )
Moves to a specified position in the recordset - either an offset, or an absolute position.
If an absolute position is given, the offset is ignored.
If there are changes to the current record, these are applied to the DB server first.
Returns 1 if successful, 0 if unsuccessful.

=head2 apply
Apply changes to the current record back to the DB server.
Returns 1 if successful, 0 if unsuccessful.

=head2 changed
Sets the 'changed' flag, which is used internally when deciding if an 'apply' is required.

=head2 revert
Reverts the current record back to its original state.
Deletes the in-memory recordset if we were inserting a new record.

=head2 delete
Deletes the current record. Asks for confirmation first.

=head2 position
Returns the current position in the keyset ( starting at zero ).

=head1 BUGS

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