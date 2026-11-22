require "../../spec_helper"

describe "Code gen: ReferenceStorage" do
  it "builds an object in storage for a class that has a generic subclass" do
    run(<<-CRYSTAL).to_i.should eq(42)
      require "prelude"

      class Shelf(T)
        getter list_of_items = [] of T
      end

      class WideShelf(T) < Shelf(T)
        @padding = 0_i64
      end

      shelf_buffer = uninitialized ReferenceStorage(Shelf(Int32))
      shelf = Shelf(Int32).unsafe_construct(pointerof(shelf_buffer))
      shelf.list_of_items << 42
      shelf.is_a?(WideShelf(Int32)) ? 0 : shelf.list_of_items.first
      CRYSTAL
  end

  # Generic subclasses make every `Array(T)` and `Hash(K, V)` a virtual type.
  # The default Regex engine keeps tables of both in static storage.
  it "matches a regex in a program that subclasses Array and Hash" do
    run(<<-CRYSTAL).to_i.should eq(2026 + 3)
      require "prelude"

      class ListOfMatches(T) < Array(T)
      end

      class CountByName(K, V) < Hash(K, V)
      end

      list_of_matches = ListOfMatches(String).new
      "2026-11-22".scan(/[0-9]+/) { |match| list_of_matches << match[0] }
      count_by_name = CountByName(String, Int32).new
      count_by_name["matches"] = list_of_matches.size
      list_of_matches.first.to_i + count_by_name["matches"]
      CRYSTAL
  end
end
