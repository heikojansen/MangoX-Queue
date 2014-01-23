#!/usr/bin/env perl

use strict;
use warnings;
use v5.10;

use Mango;
use MangoX::Queue;

use Test::More;

my $mango = Mango->new($ENV{MANGO_URI} // 'mongodb://localhost:27017');
my $collection = $mango->db('test')->collection('mangox_queue_test');
eval { $collection->drop };
$collection->create;

my $queue = MangoX::Queue->new(collection => $collection);

test_nonblocking_consume();
test_blocking_consume();
test_custom_consume();
test_job_max_reached();

sub test_nonblocking_consume {
	enqueue $queue '82365';

	my $happened = 0;

	my $consumer_id;
	$consumer_id = consume $queue sub {
		my ($job) = @_;

		$happened++;
		if($happened == 1) {
			is($job->{data}, '82365', 'Found job 82365 in non-blocking consume');
			Mojo::IOLoop->timer(1 => sub {
				enqueue $queue '29345';
			});
		} elsif ($happened == 2) {
			is($job->{data}, '29345', 'Found job 29345 in non-blocking consume');
			release $queue $consumer_id;
			Mojo::IOLoop->stop;
		} else {
			use Data::Dumper; print Dumper $job;
			fail('Queue consumed too many items');
		}
	};

	is($happened, 0, 'Non-blocking consume successful');

	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

sub test_blocking_consume {
	enqueue $queue 'test';

	while(my $item = consume $queue) {
		ok(1, 'Found job in blocking consume');
		last;
	}
}

sub test_custom_consume {
	$collection->remove;

	my $id = enqueue $queue 'custom consume test';

	my $happened = 0;

	my $consumer_id;
	$consumer_id = consume $queue status => 'Failed', sub {
		my ($job) = @_;

		isnt($job, undef, 'Found failed job in non-blocking custom consume');

		release $queue $consumer_id;
		Mojo::IOLoop->stop;
		return;
	};

	is($happened, 0, 'Non-blocking consume successful');

	Mojo::IOLoop->timer(1 => sub {
		my $job = get $queue $id;
		$job->{status} = 'Failed';
		update $queue $job;
	});

	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

sub test_job_max_reached {
	my $queue_job_max_backup = $queue->job_max;
	my $jobs = [];
	my $consumed_job_count = 0;
	my $job_max_reached_flag;
	my $consumer_id;

	$queue->job_max(5);

	# Enqueue 10 dummy jobs
	$queue->enqueue($_) for (1..10);

	# Start consuming jobs
	$consumer_id = consume $queue sub {
		my ($job) = @_;

		$consumed_job_count++;

		# Push jobs to array so we can finish() them later
		push(@$jobs, $job);
	};

	# Subscribe to the 'job_max_reached' event so we know when consuming has paused
	$queue->on(job_max_reached => sub {
		$job_max_reached_flag = 1;

		# Finish the jobs previously stored in the array
		while (my $job = shift(@$jobs)) {
			$job->finish;
		}
	});

	# Start waiting for all jobs to finish
	Mojo::IOLoop->timer(0 => sub { _wait_test_job_max_reached($queue, $consumer_id, \$consumed_job_count, $jobs); });
	Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

	ok($consumed_job_count == 10, 'consumed_job_count == 10');
	ok($job_max_reached_flag, 'job_max was reached');

	$queue->job_max($queue_job_max_backup);
}

sub _wait_test_job_max_reached {
	my ($queue, $consumer_id, $consumed_job_count, $jobs) = @_;

	if ($$consumed_job_count == 10) {
		# Make sure there are no un-finished jobs
		while (my $job = shift(@$jobs)) {
			$job->finish;
		}

		$queue->release($consumer_id);
		Mojo::IOLoop->stop;
	}
	else {
		$queue->delay->wait(sub {
			_wait_test_job_max_reached($queue, $consumer_id, $consumed_job_count, $jobs);
		});
	}
}

done_testing;
