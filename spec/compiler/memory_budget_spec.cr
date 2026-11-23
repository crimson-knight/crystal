require "../spec_helper"

describe Crystal::MemoryBudget do
  it "reads sizes in gigabytes, megabytes and plain megabytes" do
    Crystal::MemoryBudget.parse("4G").bytes.should eq(4_i64 * 1024 ** 3)
    Crystal::MemoryBudget.parse("4096M").bytes.should eq(4_i64 * 1024 ** 3)
    Crystal::MemoryBudget.parse("2048").bytes.should eq(2_i64 * 1024 ** 3)
    Crystal::MemoryBudget.parse("1.5g").bytes.should eq(1536_i64 * 1024 ** 2)
    Crystal::MemoryBudget.parse("3GB").bytes.should eq(3_i64 * 1024 ** 3)
  end

  it "rejects sizes it cannot read and sizes below 256 MB" do
    expect_raises(Crystal::Error, "Invalid memory budget: four") { Crystal::MemoryBudget.parse("four") }
    expect_raises(Crystal::Error, "at least 256M") { Crystal::MemoryBudget.parse("100M") }
  end

  it "lowers the IR kept in memory and the object stage's budget, never raises them" do
    compiler = Crystal::Compiler.new
    budget = Crystal::MemoryBudget.parse("2G")
    budget.resident_ir_megabytes.should eq(64)
    budget.object_stage_bytes.should eq(2_i64 * 1024 ** 3 - 256_i64 * 1024 ** 2)

    budget.apply(compiler)
    compiler.memory_budget.should eq(budget)
    compiler.resident_ir_megabytes.should eq(64)
    compiler.codegen_worker_memory_budget_bytes.should eq(budget.object_stage_bytes)

    compiler = Crystal::Compiler.new
    compiler.resident_ir_megabytes = 32
    compiler.codegen_worker_memory_budget_bytes = 512_i64 * 1024 ** 2
    budget.apply(compiler)
    compiler.resident_ir_megabytes.should eq(32)
    compiler.codegen_worker_memory_budget_bytes.should eq(512_i64 * 1024 ** 2)
  end

  it "keeps the default IR in memory for a large budget" do
    Crystal::MemoryBudget.parse("16G").resident_ir_megabytes.should eq(Crystal::Compiler::DEFAULT_RESIDENT_IR_MEGABYTES)
  end
end

describe Crystal::VirtualFile do
  it "keeps a long expansion in the macro source store and reads it back" do
    text = "def foo\n  1\nend\n" * 100
    store = Crystal::MacroSourceStore.open.should_not be_nil
    file = Crystal::VirtualFile.new(Crystal::Macro.new("long", [] of Crystal::Arg, Crystal::Nop.new), text, nil, store)
    file.source_in_heap.should be_nil
    file.source.should eq(text)
    other = Crystal::VirtualFile.new(Crystal::Macro.new("other", [] of Crystal::Arg, Crystal::Nop.new), text.upcase, nil, store)
    other.source.should eq(text.upcase)
    file.source.should eq(text)
  end

  it "keeps a short expansion in the heap" do
    file = Crystal::VirtualFile.new(Crystal::Macro.new("short", [] of Crystal::Arg, Crystal::Nop.new), "def foo; end", nil, Crystal::MacroSourceStore.open)
    file.source_in_heap.should eq("def foo; end")
    file.source.should eq("def foo; end")
  end

  it "has no text once released" do
    file = Crystal::VirtualFile.new(Crystal::Macro.new("long", [] of Crystal::Arg, Crystal::Nop.new), "x = 1\n" * 100, nil, Crystal::MacroSourceStore.open)
    file.release_source
    file.source.should eq("")
    file.source_in_heap.should be_nil
  end
end
