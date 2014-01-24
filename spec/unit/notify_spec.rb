require 'spec_helper'

describe "An insertion into que_jobs" do
  it "should not fail if there are no lockers registered" do
    Que::Job.enqueue
    DB[:que_jobs].select_map(:job_class).should == ['Que::Job']
  end

  it "should notify a locker if one is available" do
    DB.synchronize do |conn|
      begin
        DB[:que_lockers].insert :pid           => 1,
                                :worker_count  => 4,
                                :ruby_pid      => Process.pid,
                                :ruby_hostname => Socket.gethostname,
                                :queue         => ''

        notify_pid = Que.execute("SELECT pg_backend_pid()").first[:pg_backend_pid].to_i
        conn.async_exec "LISTEN que_locker_1"

        Que::Job.enqueue
        job = DB[:que_jobs].first

        conn.wait_for_notify do |channel, pid, payload|
          channel.should == "que_locker_1"
          pid.should == notify_pid

          json = JSON.load(payload)
          json.keys.sort.should == %w(job_id priority queue run_at)
          json['job_id'].should == job[:job_id]
          json['queue'].should == job[:queue]
          json['priority'].should == 100
          Time.parse(json['run_at']).should be_within(3).of Time.now
        end

        conn.wait_for_notify(0.01).should be nil
      ensure
        conn.async_exec "UNLISTEN *"
      end
    end
  end

  it "should not notify lockers of different queues" do
    DB.synchronize do |conn|
      begin
        DB[:que_lockers].insert :pid           => 1,
                                :worker_count  => 4,
                                :ruby_pid      => Process.pid,
                                :ruby_hostname => Socket.gethostname,
                                :queue         => 'other_queue'

        notify_pid = Que.execute("SELECT pg_backend_pid()").first[:pg_backend_pid].to_i
        conn.async_exec "LISTEN que_locker_1"

        Que::Job.enqueue
        conn.wait_for_notify(0.01).should be nil
        DB[:que_jobs].delete

        Que::Job.enqueue :queue => 'other_queue'
        job = DB[:que_jobs].first

        conn.wait_for_notify do |channel, pid, payload|
          channel.should == "que_locker_1"
          pid.should == notify_pid

          json = JSON.load(payload)
          json.keys.sort.should == %w(job_id priority queue run_at)
          json['job_id'].should == job[:job_id]
          json['queue'].should == job[:queue]
          json['priority'].should == 100
          Time.parse(json['run_at']).should be_within(3).of Time.now
        end

        conn.wait_for_notify(0.01).should be nil
      ensure
        conn.async_exec "UNLISTEN *"
      end
    end
  end

  it "should cycle between different lockers weighted by their worker_counts" do
    DB.synchronize do |conn|
      begin
        DB[:que_lockers].insert :pid           => 1,
                                :worker_count  => 1,
                                :ruby_pid      => Process.pid,
                                :ruby_hostname => Socket.gethostname,
                                :queue         => ''

        DB[:que_lockers].insert :pid           => 2,
                                :worker_count  => 2,
                                :ruby_pid      => Process.pid,
                                :ruby_hostname => Socket.gethostname,
                                :queue         => ''

        notify_pid = Que.execute("SELECT pg_backend_pid()").first[:pg_backend_pid].to_i
        conn.async_exec "LISTEN que_locker_1; LISTEN que_locker_2"

        channels = 6.times.map { Que::Job.enqueue; conn.wait_for_notify }
        channels.sort.should == ['que_locker_1'] * 2 + ['que_locker_2'] * 4

        conn.wait_for_notify(0.01).should be nil
      ensure
        conn.async_exec "UNLISTEN *"
      end
    end
  end
end
