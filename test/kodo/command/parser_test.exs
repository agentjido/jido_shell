defmodule Kodo.Command.ParserTest do
  use Kodo.Case, async: true

  alias Kodo.Command.Parser

  describe "parse/1" do
    test "parses simple command" do
      assert {:ok, "echo", []} = Parser.parse("echo")
    end

    test "parses command with arguments" do
      assert {:ok, "echo", ["hello", "world"]} = Parser.parse("echo hello world")
    end

    test "parses quoted strings as single argument" do
      assert {:ok, "echo", ["hello world"]} = Parser.parse(~s(echo "hello world"))
    end

    test "parses mixed quoted and unquoted arguments" do
      assert {:ok, "echo", ["hello", "world bar", "baz"]} =
               Parser.parse(~s(echo hello "world bar" baz))
    end

    test "handles multiple spaces between arguments" do
      assert {:ok, "echo", ["a", "b"]} = Parser.parse("echo   a    b")
    end

    test "trims leading and trailing whitespace" do
      assert {:ok, "echo", ["hello"]} = Parser.parse("  echo hello  ")
    end

    test "returns error for empty input" do
      assert {:error, :empty_command} = Parser.parse("")
    end

    test "returns error for whitespace-only input" do
      assert {:error, :empty_command} = Parser.parse("   ")
    end

    test "returns error for unclosed quote" do
      assert {:error, :unclosed_quote} = Parser.parse(~s(echo "hello))
    end

    test "handles empty quoted string" do
      assert {:ok, "echo", [""]} = Parser.parse(~s(echo ""))
    end

    test "handles quotes adjacent to text" do
      assert {:ok, "echo", ["helloworld"]} = Parser.parse(~s(echo hello"world"))
    end

    test "handles unicode characters" do
      assert {:ok, "echo", ["héllo", "wörld"]} = Parser.parse("echo héllo wörld")
    end

    test "handles quoted unicode" do
      assert {:ok, "echo", ["héllo wörld"]} = Parser.parse(~s(echo "héllo wörld"))
    end
  end
end
