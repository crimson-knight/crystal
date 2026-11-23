require "../../spec_helper"

# Programs whose generic methods are typed once for every instance run the
# same as with one copy per instance: the bounded type parameter is read from
# the receiver at run time.

private MODELS = %(
  require "prelude"

  abstract class Model
    def self.table : String
      "models"
    end

    abstract def label : String
  end

  class Post < Model
    def self.table : String
      "posts"
    end

    def label : String
      "post"
    end
  end

  class User < Model
    def self.table : String
      "users"
    end

    def label : String
      "user"
    end
  end

  class Admin < User
    def self.table : String
      "admins"
    end

    def label : String
      "admin"
    end
  end

  class Guest < Model
    def label : String
      "guest"
    end
  end

  @[TypeBound(M, Model)]
  class Query(M)
    def initialize(@limit : Int32)
    end

    def limit : Int32
      @limit
    end

    @[TypeOnce]
    def sql(prefix : String) : String
      "\#{prefix} \#{M.table} LIMIT \#{limit}"
    end

    @[TypeOnce]
    def first_label : String
      M.new.label
    end

    @[TypeOnce]
    def model_name : String
      M.name
    end
  end
  )

describe "Code gen: typed once for every instance of a generic class" do
  it "dispatches through the bounded parameter on the receiver's own type argument" do
    run(MODELS + %(
      [Query(Post).new(1).sql("FROM"), Query(User).new(2).sql("FROM"), Query(Admin).new(3).sql("FROM"), Query(Guest).new(4).sql("FROM")].join(", ")
      )).to_string.should eq("FROM posts LIMIT 1, FROM users LIMIT 2, FROM admins LIMIT 3, FROM models LIMIT 4")
  end

  it "creates an instance of the receiver's type argument" do
    run(MODELS + %(
      [Query(Post).new(1).first_label, Query(User).new(1).first_label, Query(Admin).new(1).first_label, Query(Guest).new(1).first_label].join(" ")
      )).to_string.should eq("post user admin guest")
  end

  it "reads the class of the type argument as a value" do
    run(MODELS + %(
      Query(Admin).new(1).model_name + " " + Query(Post).new(1).model_name
      )).to_string.should eq("Admin Post")
  end

  it "generates one function for every instance" do
    program = semantic(MODELS + %(
      Query(Post).new(1).sql("a")
      Query(User).new(1).sql("b")
      Query(Admin).new(1).sql("c")
      )).program
    generic = program.types["Query"].as(Crystal::GenericClassType)
    copies = generic.instantiated_types.sum do |instance|
      instance.as(Crystal::DefInstanceContainer).def_instances.count { |_, typed_def| typed_def.name == "sql" }
    end
    copies.should eq(1)
  end

  it "runs the copy for a subclass of an instance" do
    run(MODELS + %(
      class PostQuery < Query(Post)
      end

      query = PostQuery.new(5).as(Query(Post))
      query.sql("FROM") + " / " + Query(User).new(6).sql("FROM")
      )).to_string.should eq("FROM posts LIMIT 5 / FROM users LIMIT 6")
  end

  it "keeps an instance whose layout differs on its own copy and runs it" do
    run(MODELS + %(
      @[TypeBound(M, Model)]
      class Slot(M)
        def initialize(@value : M | Int32)
        end

        @[TypeOnce]
        def describe : String
          value = @value
          value.is_a?(Int32) ? "number \#{value}" : "model \#{value.label}"
        end
      end

      Slot(Post).new(Post.new).describe + ", " + Slot(User).new(7).describe
      )).to_string.should eq("model post, number 7")
  end

  it "shares a copy between instances that differ only in the bounded argument" do
    run(MODELS + %(
      @[TypeBound(M, Model)]
      class Pair(M, V)
        def initialize(@value : V)
        end

        def value : V
          @value
        end

        @[TypeOnce]
        def describe : String
          "\#{M.table}=\#{value}"
        end
      end

      [Pair(Post, Int32).new(1).describe, Pair(User, Int32).new(2).describe, Pair(Admin, String).new("x").describe].join(" ")
      )).to_string.should eq("posts=1 users=2 admins=x")
  end

  it "returns the receiver from a method that returns self, typed as the caller's instance" do
    run(MODELS + %(
    class Query(M)
      def grow : Nil
        @limit = @limit + 1
      end

      @[TypeOnce]
      def grow! : self
        grow
        self
      end
    end

    post = Query(Post).new(1).grow!.grow!
    admin = Query(Admin).new(10).grow!
    post.sql("p") + " " + admin.sql("a") + " " + typeof(post).name
    )).to_string.should eq("p posts LIMIT 3 a admins LIMIT 11 Query(Post)")
  end

  it "sets an instance variable whose type mentions the parameter to nil" do
    run(MODELS + %(
    @[TypeBound(M, Model)]
    class Cache(M)
      def initialize(@item : M?, @hits : Int32)
      end

      def item : M?
        @item
      end

      @[TypeOnce]
      def clear : Int32
        @item = nil
        @hits
      end
    end

    post = Cache(Post).new(Post.new, 3)
    user = Cache(User).new(User.new, 4)
    total = post.clear + user.clear
    "\#{total} \#{post.item.nil?} \#{user.item.nil?}"
    )).to_string.should eq("7 true true")
  end

  it "reads an instance variable whose type is the bounded parameter" do
    run(MODELS + %(
    @[TypeBound(M, Model)]
    class Owned(M)
      def initialize(@owner : M)
      end

      @[TypeOnce]
      def owner_label : String
        @owner.label + "@" + M.table
      end
    end

    Owned(Post).new(Post.new).owner_label + " " + Owned(Admin).new(Admin.new).owner_label
    )).to_string.should eq("post@posts admin@admins")
  end

  it "calls methods on an instance variable that holds another bounded generic instance" do
    code = MODELS + %(
    @[TypeBound(M, Model)]
    class Printer(M)
      def initialize(@query : Query(M))
      end

      @[TypeOnce]
      def print : String
        "<" + @query.sql("SELECT") + ">"
      end
    end

    class PostQuery < Query(Post)
    end

    Printer(Post).new(PostQuery.new(1)).print + Printer(Admin).new(Query(Admin).new(2)).print
    )
    run(code).to_string.should eq("<SELECT posts LIMIT 1><SELECT admins LIMIT 2>")
    program = semantic(code).program
    generic = program.types["Printer"].as(Crystal::GenericClassType)
    generic.instantiated_types.sum { |instance| instance.as(Crystal::DefInstanceContainer).def_instances.count { |_, typed_def| typed_def.name == "print" } }.should eq(1)
  end

  it "runs a class method typed once for every instance" do
    run(MODELS + %(
      class Query(M)
        @[TypeOnce]
        def self.page(size : Int32) : Int32
          size * 10
        end
      end

      Query(Post).page(1) + Query(User).page(2) + Query(Admin).page(3)
      )).to_i.should eq(60)
  end

  it "runs a class method that reads the bounded parameter on one copy per instance" do
    run(MODELS + %(
      class Query(M)
        @[TypeOnce]
        def self.table : String
          M.table
        end
      end

      Query(Post).table + " " + Query(Admin).table
      )).to_string.should eq("posts admins")
  end

  it "calls the copy from a method of an instance" do
    run(MODELS + %(
      class Query(M)
        def wrapped : String
          "[" + sql("x") + "]"
        end
      end

      Query(Post).new(1).wrapped + Query(Admin).new(2).wrapped
      )).to_string.should eq("[x posts LIMIT 1][x admins LIMIT 2]")
  end
end
