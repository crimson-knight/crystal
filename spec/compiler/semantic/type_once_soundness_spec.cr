require "../../spec_helper"

# Uses of `@[TypeOnce]` and `@[TypeBound]` that would change what a program
# does, or fail far from their cause, are errors at the annotation (see
# `src/compiler/crystal/semantic/type_once_soundness.cr`).

private STRICT = %(
  require "strict"
  )

# Grant's validations: `before_validation` is a class macro of the model base
# class, and each model defines a method of the same name.
private CALLBACKS = %(
  module Validating
    def valid? : Bool
      before_validation if responds_to?(:before_validation)
      true
    end
  end

  abstract class Model
    include Validating

    macro before_validation(*names)
      {% for name in names %}
        @@registered = {{name}}
      {% end %}
    end

    macro inherited
      def before_validation
        @ran = true
      end
    end
  end

  class Post < Model
  end

  Post.new.valid?
  )

# Grant's `save`: compiles for each concrete model, not for the base class.
private MODELS = %(
  abstract class Model
    macro inherited
      def save : Int32
        1
      end
    end

    def save : Int32
      {% raise "save needs a concrete model, not \#{@type}" if @type == Model %}
      0
    end
  end

  class Post < Model
  end
  )

# Grant's `order(sql : String | Trusted)` and its `order!` overloads.
private ORDER = %(
  struct Trusted
    def initialize(@sql : String)
    end
  end

  class Query
    def order!(sql : String) : Int32
      1
    end

    def order!(dsl) : Int32
      dsl.columns
    end
  end
  )

private BOUNDED = %(
  class Model
    def self.table_name : String
      "models"
    end

    def self.query : Builder(self)
      Builder(self).new
    end
  end

  class Post < Model
    def self.table_name : String
      "posts"
    end
  end

  @[TypeBound(M, Model)]
  class Builder(M)
    @[TypeOnce]
    def table : String
      M.table_name
    end
  end
  )

# Expects a type error whose text holds each of *parts*.
private def assert_type_once_error(code : String, *parts : String, inject_primitives = false, file = __FILE__, line = __LINE__) : Nil
  error = expect_raises(Crystal::TypeException, parts.first, file, line) do
    semantic(code, inject_primitives: inject_primitives)
  end
  text = error.to_s
  parts.each { |part| text.should contain(part), file: file, line: line }
end

# Types *code* followed by each call in *expected* (call => type), with its
# `@[TypeOnce]` marks and without them, and expects the call to have that type
# both ways.
private def assert_same_type_typed_once_and_per_receiver(code : String, expected : Hash(String, String), file = __FILE__, line = __LINE__) : Nil
  expected.each do |call, type|
    program = "#{code}\n#{call}\n"
    per_receiver = semantic(program.gsub("@[TypeOnce]\n", "")).node.type.to_s
    typed_once = semantic(program).node.type.to_s
    per_receiver.should eq(type), file: file, line: line
    typed_once.should eq(per_receiver), file: file, line: line
  end
end

describe "Semantic: unsafe @[TypeOnce] and @[TypeBound]" do
  describe "a macro called on the receiver" do
    it "compiles typed for each receiver" do
      assert_no_errors CALLBACKS
    end

    it "is an error when the call finds a macro for the declaring type and a method on the receiver" do
      assert_type_once_error CALLBACKS.sub("    def valid? : Bool", "    @[TypeOnce]\n    def valid? : Bool"),
        "@[TypeOnce] method 'Validating#valid?' can't call the macro 'before_validation'"
    end

    it "names the subclass method the call would skip" do
      assert_type_once_error CALLBACKS.sub("    def valid? : Bool", "    @[TypeOnce]\n    def valid? : Bool"),
        "Post defines a method 'before_validation', which this call runs when the method is typed for each receiver; typed once, it never runs"
    end

    it "is an error in a strict file" do
      assert_type_once_error STRICT + CALLBACKS,
        "method 'Validating#valid?', typed once in a strict file, can't call the macro 'before_validation'"
    end

    it "is an error for a macro that reads the receiver's type" do
      assert_type_once_error %(
        macro name_of_type
          {{ @type.name.stringify }}
        end

        class Model
          @[TypeOnce]
          def label : String
            name_of_type
          end
        end

        class Post < Model
        end

        Post.new.label
        ), "@[TypeOnce] method 'Model#label' can't call the macro 'name_of_type'", "the method is typed once for Model and every subclass, so the macro expands once, for Model, instead of once for each receiver"
    end

    it "accepts a macro called on a type" do
      assert_no_errors %(
        class Labels
          macro default
            "label"
          end
        end

        class Model
          @[TypeOnce]
          def label : String
            Labels.default
          end
        end

        class Post < Model
        end

        Post.new.label
        )
    end
  end

  describe "a body that does not compile for the declared types" do
    it "compiles typed for each caller" do
      assert_no_errors MODELS + %(
        def store(record : Model) : Int32
          record.save
        end

        store(Post.new)
        )
    end

    it "is an error at the annotation that names the method, its declared types and the failure" do
      assert_type_once_error MODELS + %(
        @[TypeOnce]
        def store(record : Model) : Int32
          record.save
        end

        store(Post.new)
        ), "@[TypeOnce] method 'store' can't be typed once: typed for its declared types (record : Model+), its body fails: save needs a concrete model, not Model"
    end

    it "names the call in the body that fails" do
      assert_type_once_error %(
        class Record
          def publish_all : Int32
            publish
          end
        end

        class Post < Record
          def publish : Int32
            1
          end
        end

        @[TypeOnce]
        def release(record : Record) : Int32
          record.publish_all
        end

        release(Post.new)
        ), "@[TypeOnce] method 'release' can't be typed once: typed for its declared types (record : Record+), the call 'Record+#publish_all()'", "fails: undefined local variable or method 'publish' for Record"
    end

    it "names the types the callers pass" do
      assert_type_once_error MODELS + %(
        @[TypeOnce]
        def store(record : Model) : Int32
          record.save
        end

        store(Post.new)
        ), "Callers here pass (record : Post); remove @[TypeOnce] to type the method for each caller"
    end
  end

  describe "a union parameter passed whole to overloads" do
    it "compiles typed for each caller" do
      assert_no_errors ORDER + %(
        class Query
          def order(sql : String | Trusted) : Int32
            order!(sql)
          end
        end

        Query.new.order("name")
        )
    end

    it "is an error that names the member and the untyped overload it reaches" do
      assert_type_once_error ORDER + %(
        class Query
          @[TypeOnce]
          def order(sql : String | Trusted) : Int32
            order!(sql)
          end
        end

        Query.new.order("name")
        ), "@[TypeOnce] method 'Query#order' can't be typed once: it passes parameter 'sql' (String | Trusted) whole to 'order!', so each member of the union picks its own overload, and Trusted reaches 'Query#order!(dsl)'", ", whose parameter 'dsl' has no type restriction. That overload fails: undefined method 'columns'"
    end
  end

  describe "a bound the program passes itself" do
    it "accepts subclasses of the bound" do
      assert_no_errors BOUNDED + %(
        Post.query.table
        ), inject_primitives: true
    end

    it "is an error at the annotation when a Model.class value builds the instance of the bound" do
      assert_type_once_error BOUNDED + %(
        Post.query.table
        model = Post.as(Model.class)
        model.query.table
        ), "@[TypeBound(M, Model)] on Builder(M) can't hold: the program uses Builder(Model), the bound itself", inject_primitives: true
    end

    it "is the same error when the instance of the bound comes first" do
      assert_type_once_error BOUNDED + %(
        model = Post.as(Model.class)
        model.query.table
        Post.query.table
        ), "@[TypeBound(M, Model)] on Builder(M) can't hold", inject_primitives: true
    end
  end
  describe "a macro called by a plain method the typed-once method calls" do
    saving = CALLBACKS.sub("    include Validating
", "    include Validating

    def save : Bool
      valid?
    end
").sub("Post.new.valid?", "Post.new.save")

    it "compiles typed for each receiver" do
      assert_no_errors saving
    end

    it "is an error: the plain method is typed once with it and the macro expands for the declaring type" do
      assert_type_once_error saving.sub("    def save : Bool", "    @[TypeOnce]
    def save : Bool"),
        "@[TypeOnce] method 'Model#save' can't call 'Validating#valid?'",
        "so 'Validating#valid?' is typed once for them too, and it calls the macro 'before_validation'"
    end

    it "is an error through a chain of plain methods" do
      chained = saving.sub("    def save : Bool
      valid?
    end
", "    def save : Bool
      check
    end

    def check : Bool
      valid?
    end
")
      assert_type_once_error chained.sub("    def save : Bool", "    @[TypeOnce]
    def save : Bool"),
        "@[TypeOnce] method 'Model#save' can't call 'Model#check'",
        "'Validating#valid?', which calls the macro 'before_validation'"
    end

    it "accepts a plain method that calls no macro" do
      assert_no_errors %(
        module Naming
          def label : String
            "model"
          end
        end

        class Model
          include Naming

          @[TypeOnce]
          def title : String
            label
          end
        end

        class Post < Model
        end

        Post.new.title
        )
    end
  end

  describe "self as the declared return type" do
    returning_self = %(
      class Model
        @[TypeOnce]
        def touch : self
          self
        end
      end

      class Post < Model
        def post_only : Int32
          1
        end
      end

      Post.new.touch
      )

    it "compiles typed for each receiver" do
      assert_no_errors returning_self.sub("        @[TypeOnce]
", "")
    end

    it "is an error for an instance method typed once for a class and its subclasses" do
      assert_type_once_error returning_self,
        "@[TypeOnce] method 'Model#touch' can't declare its return type as 'self'",
        "so 'self' in the return type is Model+ for every caller"
    end

    it "is an error for a nilable self" do
      assert_type_once_error returning_self.sub("def touch : self", "def touch : self?"),
        "@[TypeOnce] method 'Model#touch' can't declare its return type"
    end

    it "accepts a class method, typed for each receiver" do
      assert_no_errors %(
        class Model
          @[TypeOnce]
          def self.build : self
            new
          end
        end

        class Post < Model
        end

        Post.build
        )
    end

    it "is an error for self inside a generic return type" do
      assert_type_once_error returning_self.sub("def touch : self\n          self", "def touch : Array(self)\n          [self]"),
        "@[TypeOnce] method 'Model#touch' can't declare its return type as 'Array(self)'",
        "(this call's receiver is Post)"
    end

    it "accepts a call whose receiver is already the shared type, typed as it is for each receiver" do
      assert_same_type_typed_once_and_per_receiver %(
        class Model
          @[TypeOnce]
          def touch(other : Model) : self
            self
          end
        end

        class Post < Model
        end

        def flip : Bool
          true
        end

        model = flip ? Model.new : Post.new
        ), {"model.touch(Post.new)" => "Model+"}
    end

    # Grant's `Builder(Model)`: a model with a named scope gets a subclass of
    # its builder, so the builder is `Builder(Post)+`.
    it "accepts a method of a generic class called on the class and its subclasses, typed as it is for each receiver" do
      assert_same_type_typed_once_and_per_receiver %(
        class Model
        end

        class Post < Model
        end

        class Builder(M)
          @[TypeOnce]
          def where(record : Model) : self
            self
          end

          @[TypeOnce]
          def first? : self?
            self
          end
        end

        class PostScopes < Builder(Post)
        end

        def flip : Bool
          true
        end

        builder = flip ? Builder(Post).new : PostScopes.new
        ), {"builder.where(Post.new)" => "Builder(Post)+", "builder.first?" => "Builder(Post)+"}
    end

    # Grant's class-level finders: a model with subclasses is `Model.class+`
    # at the class level.
    it "accepts a class method called on the class and its subclasses, typed as it is for each receiver" do
      assert_same_type_typed_once_and_per_receiver %(
        class Model
          @[TypeOnce]
          def self.build(template : Model) : self
            new
          end

          @[TypeOnce]
          def self.build_box(template : Model) : Box(self)
            Box(self).new
          end
        end

        class Post < Model
        end

        class Box(T)
        end

        def flip : Bool
          true
        end

        model_class = flip ? Model : Post
        ), {"model_class.build(Post.new)" => "Model+", "model_class.build_box(Post.new)" => "Box(Model)"}
    end
  end
end
