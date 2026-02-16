defmodule Jido.Shell.Command.ParserTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Command.Parser

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

    test "handles escaped spaces and separators" do
      assert {:ok, "echo", ["hello world;still_one"]} = Parser.parse("echo hello\\ world\\;still_one")
    end

    test "handles escaped quotes inside double quotes" do
      assert {:ok, "echo", ["he said \"hi\""]} = Parser.parse(~s(echo "he said \\"hi\\""))
    end

    test "handles unicode characters" do
      assert {:ok, "echo", ["héllo", "wörld"]} = Parser.parse("echo héllo wörld")
    end

    test "handles quoted unicode" do
      assert {:ok, "echo", ["héllo wörld"]} = Parser.parse(~s(echo "héllo wörld"))
    end

    test "rejects chained commands in parse/1" do
      assert {:error, :chained_command} = Parser.parse("echo hi; pwd")
    end
  end

  describe "parse_program/1" do
    test "parses semicolon chaining" do
      assert {:ok,
              [
                %{operator: :always, command: "echo", args: ["one"]},
                %{operator: :always, command: "echo", args: ["two"]}
              ]} = Parser.parse_program("echo one; echo two")
    end

    test "parses and-if chaining" do
      assert {:ok,
              [
                %{operator: :always, command: "echo", args: ["one"]},
                %{operator: :and_if, command: "echo", args: ["two"]}
              ]} = Parser.parse_program("echo one && echo two")
    end

    test "preserves quoted separators" do
      assert {:ok,
              [
                %{operator: :always, command: "echo", args: ["a;b&&c"]}
              ]} = Parser.parse_program(~s(echo "a;b&&c"))
    end

    test "returns syntax error on trailing operator" do
      assert {:error, :trailing_operator} = Parser.parse_program("echo hi &&")
    end

    test "returns syntax error on invalid operator position" do
      assert {:error, :invalid_operator_position} = Parser.parse_program("&& echo hi")
    end

    test "returns unclosed quote error" do
      assert {:error, :unclosed_quote} = Parser.parse_program(~s(echo "hello))
    end
  end
end
