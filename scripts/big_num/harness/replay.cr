require "./subject"
require "./differential_run"

module G2Harness
  # Replays one index and returns "same", or the operands and both results.
  def self.replay(subject : String, operation : String, seed : UInt64, index : UInt64, max_bits : Int32, injected : Bool = false) : String
    trial = Subject.dispatch(subject) { replay_trial(subject_type, operation, seed, index, max_bits, injected) }
    return "same" unless trial.difference?
    String.build do |io|
      io << operation << " seed=" << seed << " index=" << index << '\n'
      trial.operands.each_with_index { |operand, position| io << "operand " << position << ": " << operand << '\n' }
      io << "gmp:     " << trial.oracle << '\n'
      io << "subject: " << trial.subject << '\n'
    end
  end

  def self.replay_trial(type : T.class, operation : String, seed : UInt64, index : UInt64, max_bits : Int32, injected : Bool) : Trial forall T
    injection = injected ? [operation] : [] of String
    Operations(T).new(injection).run(operation, OperandSource.new(Random::PCG32.new(seed, index), max_bits))
  end
end
