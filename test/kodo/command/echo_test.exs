defmodule Kodo.Command.EchoTest do
  use Kodo.Case, async: true

  alias Kodo.Command.Echo
  alias Kodo.Session.State

  setup do
    {:ok, state} = State.new(%{id: "test", workspace_id: :test})
    {:ok, state: state}
  end

  describe "name/0" do
    test "returns echo" do
      assert Echo.name() == "echo"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Echo.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Echo.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
      assert {:ok, %{args: ["a", "b"]}} = Zoi.parse(schema, %{args: ["a", "b"]})
    end
  end

  describe "run/3" do
    test "emits output with joined arguments", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = Echo.run(state, %{args: ["hello", "world"]}, emit)

      assert {:ok, nil} = result
      assert_receive {:emit, {:output, "hello world\n"}}
    end

    test "emits newline for empty arguments", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = Echo.run(state, %{args: []}, emit)

      assert {:ok, nil} = result
      assert_receive {:emit, {:output, "\n"}}
    end

    test "handles single argument", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = Echo.run(state, %{args: ["single"]}, emit)

      assert {:ok, nil} = result
      assert_receive {:emit, {:output, "single\n"}}
    end
  end
end
