# An object oriented interface to the data structure as returned by
# nqp::mvmendprofile, when started with mvmstartprofile({:instrumented})

# We need NQP here, duh!
use nqp;

# Simple role that maps a set of given keys onto a hash, so that we need to
# do the minimal amount of work to convert the data structure to a full-blown
# object hierarchy.
role OnHash[@keys] {
    has %.hash;

    # this gets run at mixin time, before the class is composed
    for @keys -> $key {
        $?CLASS.^add_method($key, { .hash.AT-KEY($key) } )
    }

    # don't want to use named parameters for something this simple
    method new(%hash) { self.bless(:%hash) }

    # make sure we have an object, and not just a hash for a given key
    method !mogrify-to-object(\the-class, \key --> Nil) {
        if %!hash{key} -> $hash {
            %!hash{key} = the-class.new($hash) unless $hash ~~ the-class;
        }
        else {
            %!hash{key} = the-class.new({});
        }
    }

    # make sure we have a list of objects, and not just an array of hashes
    method !mogrify-to-list(\the-class, \key --> Nil) {
        if %!hash{key} -> @list {
            %!hash{key} = @list.map( {
                $_ ~~ the-class ?? $_ !! the-class.new($_)
            } ).list;
        }
        else {
            %!hash{key} = ()
        }
    }
}

# Information about objects of a certain type being allocated in a Callee.
class MoarVM::Profiler::Allocation does OnHash[<
  count
  id
  jit
>] { }

# Information about a frame that has been called.
class MoarVM::Profiler::Callee does OnHash[<
  allocations
  callees
  entries
  exclusive_time
  file
  first_entry_time
  id
  inclusive_time
  inlined_entries
  jit_entries
  line
  name
  osr
>] {

    method TWEAK(--> Nil) {
        self!mogrify-to-list(MoarVM::Profiler::Allocation, 'allocations');
        self!mogrify-to-list(MoarVM::Profiler::Callee,     'callees'    );
    }

    method all_callees() {
        |(|self.callees, |self.callees.map: *.all_callees)
    }
    method all_allocations() {
        |(|self.allocations, |self.callees.map: *.all_allocations)
    }

    method nr_allocations(--> Int:D) {
        self.allocations.map(*.count).sum
          + self.callees.map(*.nr_allocations).sum
    }
    method nr_frames(--> Int:D) {
        (self.entries // 0) + self.callees.map(*.nr_frames).sum
    }
    method nr_inlined(--> Int:D) {
        (self.inlined_entries // 0) + self.callees.map(*.nr_inlined).sum
    }
    method nr_jitted(--> Int:D) {
        (self.jit_entries // 0) + self.callees.map(*.nr_jitted).sum
    }
    method nr_osred(--> Int:D) {
        (self.osr // 0) + self.callees.map(*.nr_osred).sum
    }
}

# Information about a de-allocation as part of a garbage collection.
class MoarVM::Profiler::Deallocation does OnHash[<
  id
  nursery_fresh
  nursery_seen
>] { }


# Information about a garbage collection.
class MoarVM::Profiler::GC does OnHash[<
  cleared_bytes
  deallocs
  full
  gen2_roots
  promoted_bytes
  promoted_bytes_unmanaged
  responsible
  retained_bytes
  sequence
  start_time
  time
>] {

    method TWEAK(--> Nil) {
        self!mogrify-to-list(MoarVM::Profiler::Deallocation, 'deallocs');
    }
}

# Information about a type that have at least one object instantiated.
class MoarVM::Profiler::Type does OnHash[<
  managed_size
  repr
  type
  has_unmanaged_data
>] {
    has Int $.id;
    has %.threads;  # set by MoarVM::Profiler.new

    method new( ($id,%hash) ) { self.bless(:$id, :%hash) }
    method TWEAK() {
        $_ = (try .^name) || "(" ~ nqp::objectid($_) ~ ")" given %!hash<type>;
    }

    # thread given ID
    method thread($id) { %!threads{$id} }
}

# Information about a thread.
class MoarVM::Profiler::Thread does OnHash[<
  callee
  gcs
  parent
  spesh_time
  start_time
  total_time
>] {
    has Int $.id;
    has $.callee;
    has %.types;  # set by MoarVM::Profiler.new

    method TWEAK(--> Nil) {
        $!id := %!hash.DELETE-KEY("thread");
        %!hash.ASSIGN-KEY('callee',%!hash.DELETE-KEY("call_graph"));

        self!mogrify-to-object(MoarVM::Profiler::Callee, 'callee');
        self!mogrify-to-list(MoarVM::Profiler::GC, 'gcs');
    }

    # type given ID
    method type($id) { %!types{$id} }

    method all_callees()     { self.callee.all_callees     }
    method all_allocations() { self.callee.all_allocations }

    method nr_allocations(--> Int:D) { self.callee.nr_allocations }
    method nr_frames(--> Int:D)      { self.callee.nr_frames      }
    method nr_inlined(--> Int:D)     { self.callee.nr_inlined     }
    method nr_jitted(--> Int:D)      { self.callee.nr_jitted      }
    method nr_osred(--> Int:D)       { self.callee.nr_osred       }
    method nr_gcs(--> Int:D)         { +self.gcs                  }
}

# Main object returned by profile() and friends.
class MoarVM::Profiler {
    has %.types   is required;
    has %.threads is required;
    has %.names;

    method !SET-SELF(@raw) {
        %!types = @raw[0].map: -> $type {
            .id => $_ given MoarVM::Profiler::Type.new($type)
        }
        %!threads = @raw.skip.map: -> $thread {
            .id => $_ given MoarVM::Profiler::Thread.new($thread)
        }

        # let types know about threads and vice-versa
        nqp::bindattr(
          nqp::decont($_),MoarVM::Profiler::Type,'%!threads',%!threads
        ) for %!types.values;
        nqp::bindattr(
          nqp::decont($_),MoarVM::Profiler::Thread,'%!types',%!types
        ) for %!threads.values;

        self
    }
    method new(@raw) { self.CREATE!SET-SELF(@raw) }

    method names() {
        %!names
          ?? %!names
          !! %!names = %.types.map( { .type => $_ with .value } )
    }

    # type/thread given an ID
    method type_by_id($id)     { %!types{$id}   }
    method type_by_name($name) { %.names{$name} }
    method thread($id)         { %!threads{$id} }

    method report(--> Str:D) {
        (
"  #   wallclock   objects    frames   inlined    jitted   OSR   GCs",
"----+-----------+---------+---------+---------+---------+-----+-----",
          |self.threads.grep(*.value.nr_frames).sort(*.key).map( {
              sprintf("%3d %11d %9d %9d %9d %9d %5d %5d",
                .id,
                .total_time,
                .nr_allocations,
                .nr_frames,
                .nr_inlined,
                .nr_jitted,
                .nr_osred,
                .nr_gcs,
              ) given .value
          } ),
"----+-----------+---------+---------+---------+---------+-----+-----",
        ).join("\n")
    }

    method sink(--> Nil) {
        note self.report;
    }
}

# Raw subs, for cases where starting an extra scope would be troublesome
sub profile_start(--> Nil) is export {
    nqp::mvmstartprofile({:instrumented})
}

sub profile_end(--> MoarVM::Profiler:D) is export {
    MoarVM::Profiler.new(nqp::mvmendprofile)
}

# HLL sub for profiling a piece of code and getting the info from that
sub profile(&code --> MoarVM::Profiler:D) is export {
    nqp::mvmstartprofile({:instrumented});
    code();
    MoarVM::Profiler.new(nqp::mvmendprofile)
}
