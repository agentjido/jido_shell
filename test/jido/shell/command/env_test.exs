defmodule Jido.Shell.Command.EnvTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Command.Env
  alias Jido.Shell.Session.State
  alias Jido.Shell.VFS

  setup do
    VFS.init()
    workspace_id = :"test_ws_#{System.unique_integer([:positive])}"
    fs_name = :"test_fs_#{System.unique_integer([:positive])}"

    start_supervised!({Hako.Adapter.InMemory, {Hako.Adapter.InMemory, %Hako.Adapter.InMemory.Config{name: fs_name}}})

    :ok = VFS.mount(workspace_id, "/", Hako.Adapter.InMemory, name: fs_name)

    {:ok, state} =
      State.new(%{id: "test", workspace_id: workspace_id, cwd: "/", env: %{}})

    on_exit(fn ->
      VFS.unmount(workspace_id, "/")
    end)

    {:ok, state: state, workspace_id: workspace_id}
  end

  describe "name/0" do
    test "returns env" do
      assert Env.name() == "env"
    end
  end

  describe "summary/0" do
    test "returns a description" do
      assert is_binary(Env.summary())
    end
  end

  describe "schema/0" do
    test "returns a Zoi schema" do
      schema = Env.schema()
      assert {:ok, %{args: []}} = Zoi.parse(schema, %{})
    end
  end

  describe "run/3 with no args" do
    test "lists all env vars when env is empty", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, env} = Env.run(state, %{args: []}, emit)

      assert env == %{}
      assert_receive {:emit, {:output, "(no environment variables)\n"}}
    end

    test "lists all env vars when env has values", %{state: state} do
      state = %{state | env: %{"FOO" => "bar", "BAZ" => "qux"}}
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, env} = Env.run(state, %{args: []}, emit)

      assert env == %{"FOO" => "bar", "BAZ" => "qux"}
      assert_receive {:emit, {:output, output}}
      assert output =~ "FOO=bar"
      assert output =~ "BAZ=qux"
    end
  end

  describe "run/3 with single var name" do
    test "shows specific variable value", %{state: state} do
      state = %{state | env: %{"FOO" => "bar"}}
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, value} = Env.run(state, %{args: ["FOO"]}, emit)

      assert value == "bar"
      assert_receive {:emit, {:output, "FOO=bar\n"}}
    end

    test "shows (not set) for missing variable", %{state: state} do
      emit = fn event -> send(self(), {:emit, event}) end

      {:ok, nil} = Env.run(state, %{args: ["MISSING"]}, emit)

      assert_receive {:emit, {:output, "(not set)\n"}}
    end
  end

  describe "run/3 with assignment" do
    test "sets variable", %{state: state} do
      emit = fn _event -> :ok end

      {:ok, {:state_update, %{env: new_env}}} = Env.run(state, %{args: ["FOO=bar"]}, emit)

      assert new_env == %{"FOO" => "bar"}
    end

    test "sets variable with equals in value", %{state: state} do
      emit = fn _event -> :ok end

      {:ok, {:state_update, %{env: new_env}}} = Env.run(state, %{args: ["FOO=a=b=c"]}, emit)

      assert new_env == %{"FOO" => "a=b=c"}
    end

    test "sets empty value", %{state: state} do
      emit = fn _event -> :ok end

      {:ok, {:state_update, %{env: new_env}}} = Env.run(state, %{args: ["FOO="]}, emit)

      assert new_env == %{"FOO" => ""}
    end

    test "overwrites existing variable", %{state: state} do
      state = %{state | env: %{"FOO" => "old"}}
      emit = fn _event -> :ok end

      {:ok, {:state_update, %{env: new_env}}} = Env.run(state, %{args: ["FOO=new"]}, emit)

      assert new_env == %{"FOO" => "new"}
    end
  end

  describe "run/3 with multiple args" do
    test "returns error", %{state: state} do
      emit = fn _event -> :ok end

      {:error, error} = Env.run(state, %{args: ["FOO", "BAR"]}, emit)

      assert error.code == {:validation, :invalid_args}
      assert error.context.command == "env"
    end
  end
end
