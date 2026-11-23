require "../../spec_helper"

private def digest_after_fresh_names(code : String, count_of_fresh_names : Int32) : Crystal::InferReuse::TypedProgramDigest
  program = new_program
  count_of_fresh_names.times { program.new_temp_var_name }
  node = program.normalize(parse(code))
  node = program.semantic(node)
  Crystal::InferReuse::TypedProgramDigest.new(program, node)
end

describe Crystal::InferReuse::TypedProgramDigest do
  it "digests a body the same whatever numbers its fresh variable names got" do
    code = <<-CRYSTAL
      def both?(a : Int32, b : Int32)
        a == 1 && b == 2
      end

      both?(1, 2)
      CRYSTAL
    first = digest_after_fresh_names(code, 0)
    second = digest_after_fresh_names(code, 40)
    first.differences(second).should be_empty
  end

  it "tells apart bodies that use their fresh variables differently" do
    first = digest_after_fresh_names("def both?(a : Int32, b : Int32)\n  a == 1 && b == 2\nend\n\nboth?(1, 2)\n", 0)
    second = digest_after_fresh_names("def both?(a : Int32, b : Int32)\n  a == 1 || b == 2\nend\n\nboth?(1, 2)\n", 0)
    first.differences(second).should_not be_empty
  end
end
