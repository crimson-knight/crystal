require "../../spec_helper"

private def digest_after_fresh_names(code : String, count_of_fresh_names : Int32) : Crystal::InferReuse::TypedProgramDigest
  program = Crystal::Program.new
  count_of_fresh_names.times { program.new_temp_var_name }
  node = program.normalize(parse(code))
  node = program.semantic(node)
  Crystal::InferReuse::TypedProgramDigest.new(program, node)
end

private def program_text(operator : String) : String
  <<-CRYSTAL
    def one
      1
    end

    def two
      2
    end

    def both
      one #{operator} two
    end

    both
    CRYSTAL
end

describe Crystal::InferReuse::TypedProgramDigest do
  it "digests a body the same whatever numbers its fresh variable names got" do
    first = digest_after_fresh_names(program_text("&&"), 0)
    second = digest_after_fresh_names(program_text("&&"), 40)
    first.differences(second).should be_empty
  end

  it "tells apart bodies that use their fresh variables differently" do
    first = digest_after_fresh_names(program_text("&&"), 0)
    second = digest_after_fresh_names(program_text("||"), 0)
    first.differences(second).should_not be_empty
  end
end
