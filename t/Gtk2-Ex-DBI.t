use Test::More qw(no_plan);
#########################

BEGIN { use_ok( 'Gtk2::Ex::DBI' ); }

#########################
# are all the known methods accounted for?

my @methods = qw(
			new
			fieldlist
			query
			insert
			count
			paint
			move
			apply
			changed
			paint_calculated
			revert
			delete
		);

can_ok( 'Gtk2::Ex::DBI', @methods );
