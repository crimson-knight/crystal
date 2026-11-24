require "../../spec_helper"

# Writes that land on a copy of a struct (see
# `src/compiler/crystal/semantic/struct_copy_write.cr`).

private POINT = %(
  struct Point
    def initialize(@x : Int32, @y : Int32)
    end

    def x : Int32
      @x
    end

    def x=(@x : Int32)
    end

    def y : Int32
      @y
    end

    def y=(@y : Int32)
    end

    def +(other : Int32) : Int32
      @x + other
    end
  end
  )

private def struct_copy_warnings(code : String, inject_primitives = true) : Array(String)
  semantic(code, inject_primitives: inject_primitives).program.warnings.infos
end

private def assert_struct_copy_warning(code : String, *messages : String, inject_primitives = true, file = __FILE__, line = __LINE__)
  warnings = struct_copy_warnings(code, inject_primitives)
  copy_warnings = warnings.select(&.includes?("so the write is lost"))
  copy_warnings.size.should eq(1), file: file, line: line
  messages.each do |message|
    copy_warnings[0].should contain(message), file: file, line: line
  end
end

private def assert_no_struct_copy_warning(code : String, inject_primitives = true, file = __FILE__, line = __LINE__)
  warnings = struct_copy_warnings(code, inject_primitives)
  warnings.select(&.includes?("so the write is lost")).should be_empty, file: file, line: line
end

describe "Semantic: write to a struct copy" do
  describe "warns" do
    it "about an op-assign through Pointer#value" do
      assert_struct_copy_warning POINT + %(
        pointer = Pointer(Point).malloc(1_u64)
        pointer.value.x += 5
        ),
        "`pointer.value.x += 5` sets field 'x' of a copy of `pointer.value` (a Point struct), so the write is lost",
        "`pointer.value.x +=` copies `pointer.value` to a temporary first",
        "copy = pointer.value",
        "pointer.value = copy",
        "pointer.value.x = pointer.value.x + 5"
    end

    it "about a ||= through Pointer#value" do
      assert_struct_copy_warning POINT + %(
        struct Box
          def initialize(@count : Int32?)
          end

          def count : Int32?
            @count
          end

          def count=(@count : Int32?)
          end
        end

        pointer = Pointer(Box).malloc(1_u64)
        pointer.value.count ||= 1
        ),
        "sets field 'count' of a copy of `pointer.value`"
    end

    it "about a field set through Pointer#[]" do
      assert_struct_copy_warning POINT + %(
        struct Pointer(T)
          def [](offset : Int64) : T
            (self + offset).value
          end
        end

        pointer = Pointer(Point).malloc(2_u64)
        pointer[1_i64].x = 7
        ),
        "`pointer[1_i64].x = 7` sets field 'x' of a copy of `pointer[1_i64]` (a Point struct)",
        "(pointer + 1_i64).value.x = 7"
    end

    it "about a field set through Array#[] on an Array of structs" do
      assert_struct_copy_warning %(
        require "prelude"

        struct Point
          property x = 0
        end

        points = [Point.new]
        points[0].x = 9
        ),
        "`points[0].x = 9` sets field 'x' of a copy of `points[0]` (a Point struct)",
        inject_primitives: false
    end

    it "about a field set through Hash#[] on a Hash of structs" do
      assert_struct_copy_warning %(
        require "prelude"

        struct Point
          property x = 0
        end

        points = {"a" => Point.new}
        points["a"].x += 1
        ),
        "sets field 'x' of a copy of `points[\"a\"]` (a Point struct)",
        inject_primitives: false
    end

    it "about a field set on the result of a method that returns a struct" do
      assert_struct_copy_warning POINT + %(
        def origin : Point
          Point.new(0, 0)
        end

        origin.y = 3
        ),
        "`origin.y = 3` sets field 'y' of a copy of `origin` (a Point struct)"
    end

    it "about an op-assign through an instance variable getter" do
      assert_struct_copy_warning POINT + %(
        class Holder
          def initialize
            @point = Point.new(0, 0)
          end

          def point : Point
            @point
          end
        end

        Holder.new.point.x += 1
        ),
        "copies `Holder.new.point` to a temporary first"
    end

    it "about a nested field set through a copy" do
      assert_struct_copy_warning POINT + %(
        struct Segment
          def initialize(@start : Point)
          end

          def start : Point
            @start
          end
        end

        def segment : Segment
          Segment.new(Point.new(0, 0))
        end

        segment.start.x = 1
        ),
        "of a copy of `segment.start`"
    end

    it "once for a call in a method typed for two callers" do
      assert_struct_copy_warning POINT + %(
        def origin : Point
          Point.new(0, 0)
        end

        def move(by)
          origin.x = by
        end

        move(1)
        move(2)
        ),
        "of a copy of `origin`"
    end
  end

  describe "stays silent" do
    it "for a local struct" do
      assert_no_struct_copy_warning POINT + %(
        point = Point.new(0, 0)
        point.x = 1
        point.x += 1
        )
    end

    it "for a field set through Pointer#value" do
      assert_no_struct_copy_warning POINT + %(
        pointer = Pointer(Point).malloc(1_u64)
        pointer.value.x = 5
        pointer.value.x = pointer.value.x + 5
        (pointer + 1_i64).value.y = 2
        )
    end

    it "for an instance variable" do
      assert_no_struct_copy_warning POINT + %(
        class Holder
          def initialize
            @point = Point.new(0, 0)
          end

          def move : Nil
            @point.x = 1
            @point.x += 1
          end
        end

        Holder.new.move
        )
    end

    it "for a struct field of a class instance read through a getter" do
      assert_no_struct_copy_warning POINT + %(
        class Holder
          def initialize
            @point = Point.new(0, 0)
          end

          def point : Point
            @point
          end
        end

        holder = Holder.new
        holder.point.x = 1
        )
    end

    it "for a struct field read through .value on a reference type" do
      assert_no_struct_copy_warning POINT + %(
        class Cell
          def initialize(@value : Point)
          end

          def value : Point
            @value
          end
        end

        cell = Cell.new(Point.new(0, 0))
        cell.value.x = 4
        )
    end

    it "for a nested field set through Pointer#value and a getter" do
      assert_no_struct_copy_warning POINT + %(
        struct Segment
          def initialize(@start : Point)
          end

          def start : Point
            @start
          end
        end

        pointer = Pointer(Segment).malloc(1_u64)
        pointer.value.start.x = 3
        )
    end

    it "for a cast of a local" do
      assert_no_struct_copy_warning POINT + %(
        value = Point.new(0, 0).as(Point | Int32)
        value.as(Point).x = 1
        )
    end

    it "for self inside a struct method" do
      assert_no_struct_copy_warning POINT + %(
        struct Point
          def reset : Nil
            self.x = 0
            self.y += 1
          end
        end

        point = Point.new(1, 1)
        point.reset
        )
    end

    it "for a setter on a class returned by a method" do
      assert_no_struct_copy_warning %(
        class Counter
          def initialize(@count : Int32)
          end

          def count : Int32
            @count
          end

          def count=(@count : Int32)
          end
        end

        def counter : Counter
          Counter.new(0)
        end

        counter.count = 1
        counter.count += 1
        )
    end

    it "for a setter on a struct that writes through a pointer it holds" do
      assert_no_struct_copy_warning %(
        struct Handle
          def initialize(@target : Int32*)
          end

          def value=(value : Int32)
            @target.value = value
          end
        end

        def handle : Handle
          Handle.new(Pointer(Int32).malloc(1_u64))
        end

        handle.value = 1
        )
    end
  end

  describe "in a strict file" do
    it "is an error" do
      assert_error %(
        require "strict"
        ) + POINT + %(
        def origin : Point
          Point.new(0, 0)
        end

        origin.y = 3
        ),
        "strict file: `origin.y = 3` sets field 'y' of a copy of `origin` (a Point struct), so the write is lost",
        inject_primitives: true
    end

    it "is an error for an op-assign through Pointer#value" do
      assert_error %(
        require "strict"
        ) + POINT + %(
        pointer = Pointer(Point).malloc(1_u64)
        pointer.value.x += 5
        ),
        "strict file: `pointer.value.x += 5` sets field 'x' of a copy of `pointer.value`",
        inject_primitives: true
    end
  end
end
