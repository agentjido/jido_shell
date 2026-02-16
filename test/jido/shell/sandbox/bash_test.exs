defmodule Jido.Shell.Sandbox.BashTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Sandbox.Bash
  alias Jido.Shell.Session.State
  alias Jido.Shell.VFS

  setup do
    VFS.init()
    workspace_id = "sandbox_ws_#{System.unique_integer([:positive])}"
    fs_name = "sandbox_fs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Jido.VFS.Adapter.InMemory, {Jido.VFS.Adapter.InMemory, %Jido.VFS.Adapter.InMemory.Config{name: fs_name}}}
    )

    :ok = VFS.mount(workspace_id, "/", Jido.VFS.Adapter.InMemory, name: fs_name)

    {:ok, state} = State.new(%{id: "test", workspace_id: workspace_id, cwd: "/"})

    on_exit(fn ->
      VFS.unmount(workspace_id, "/")
    end)

    {:ok, state: state}
  end

  describe "statements/1" do
    test "splits lines and removes comments" do
      script = """
      # comment
      echo one; echo two

      pwd
      """

      assert Bash.statements(script) == ["echo one; echo two", "pwd"]
    end

    test "preserves quoted semicolons in a statement" do
      script = ~s(echo "a;b"; echo c)
      assert Bash.statements(script) == [~s(echo "a;b"; echo c)]
    end
  end

  describe "execute/3" do
    test "executes statements through command runner", %{state: state} do
      script = "echo hello\npwd"

      {result, events} =
        capture_events(fn emit ->
          Bash.execute(state, script, emit)
        end)

      assert {:ok, %State{cwd: "/"}} = result
      assert {:output, "hello\n"} in events
      assert {:output, "/\n"} in events
    end
  end

  defp capture_events(fun) do
    emit = fn event ->
      send(self(), {:event, event})
      :ok
    end

    result = fun.(emit)
    {result, receive_all_events([])}
  end

  defp receive_all_events(acc) do
    receive do
      {:event, event} -> receive_all_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
