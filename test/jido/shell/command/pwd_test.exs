defmodule Jido.Shell.Command.PwdTest do
  use Jido.Shell.Case, async: true

  alias Jido.Shell.Command.Pwd
  alias Jido.Shell.ShellSession.State

  setup do
    {:ok, state} = State.new(%{id: "test", workspace_id: "test", cwd: "/home/user"})
    {:ok, state: state}
  end

  describe "name/0" do
    test "returns pwd" do
      assert Pwd.name() == "pwd"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Pwd.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Pwd.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3" do
    test "emits current working directory", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      result = Pwd.run(state, %{args: []}, emit)

      assert {:ok, nil} = result
      assert_receive {:emit, {:output, "/home/user\n"}}
    end

    test "emits root directory when cwd is root" do
      {:ok, state} = State.new(%{id: "test", workspace_id: "test", cwd: "/"})
      emit = fn event -> send(self(), {:emit, event}) end

      result = Pwd.run(state, %{args: []}, emit)

      assert {:ok, nil} = result
      assert_receive {:emit, {:output, "/\n"}}
    end
  end
end
