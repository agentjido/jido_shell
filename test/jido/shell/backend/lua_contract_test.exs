defmodule Jido.Shell.Backend.LuaContractTest do
  use ExUnit.Case, async: false
  alias Jido.Shell.Backend.Lua, as: Backend
  alias Jido.Shell.Backend.Lua.{JidoApi, Session}
  alias Jido.Shell.Error
  alias Jido.Shell.VFS

  setup do
    name = "lua-contract-#{System.unique_integer([:positive])}"
    fs = Jido.VFS.Adapter.InMemory.configure(name: name)
    start_supervised!({Jido.VFS.Adapter.InMemory, fs})
    :ok = VFS.mount(name, "/", Jido.VFS.Adapter.InMemory, name: name)
    on_exit(fn -> VFS.unmount(name, "/") end)
    %{workspace: name}
  end

  test "stateless evaluations report syntax, runtime, and output errors", %{workspace: workspace} do
    {:ok, state} = Backend.init(%{session_pid: self(), workspace_id: workspace, persistent: false})

    for {script, code, opts} <- [
          {"local =", :syntax_error, []},
          {"error('failed')", :runtime_error, []},
          {"print('too much')", :output_limit_exceeded, [output_limit: 2]}
        ] do
      assert {:ok, handle, ^state} = Backend.execute(state, script, [], opts)
      assert_receive {:command_finished, {:error, %Error{code: {:command, ^code}}}}, 1000
      await_worker(handle.watcher_pid)
    end

    refute_received {:command_event, {:output, _}}
    assert :ok = Backend.terminate(state)
  end

  test "stateless commands return directory and environment changes", %{workspace: workspace} do
    :ok = VFS.mkdir(workspace, "/work")
    {:ok, state} = Backend.init(%{session_pid: self(), workspace_id: workspace, persistent: false})
    assert {:ok, handle, ^state} = Backend.execute(state, "jido.cd('/work');", ["jido.env('MODE=test')"], [])
    assert_receive {:command_finished, {:ok, {:state_update, %{cwd: "/work", env: %{"MODE" => "test"}}}}}, 1000
    await_worker(handle.watcher_pid)
    assert {:ok, "/", ^state} = Backend.cwd(state)
    assert {:ok, %{cwd: "/changed"}} = Backend.cd(state, "/changed")
    assert {:ok, ^state} = Backend.configure_network(state, %{})
    assert {:error, :invalid_command_ref} = Backend.cancel(state, :invalid)
    assert :ok = Backend.cancel(state, %{eval_pid: nil, watcher_pid: nil})
    assert :ok = Backend.terminate(state)
  end

  test "invalid configuration does not start a persistent holder" do
    assert {:error, %Error{code: {:session, :invalid_state_transition}}} = Backend.init(%{})

    assert {:error, %Error{code: {:command, :start_failed}}} =
             Backend.init(%{session_pid: self(), apis: [MissingLuaApi]})
  end

  test "holder shutdown is idempotent and later evaluations return a command error" do
    {:ok, holder} = Session.new(Lua.new())
    assert :ok = Session.stop(holder)
    assert :ok = Session.stop(holder)
    assert {:error, %Error{code: {:command, :crashed}}} = Session.eval(holder, "x = 1", %{})
  end

  test "a holder that stops during evaluation cannot commit its new state" do
    {:ok, holder} = Session.new(Lua.new())
    {:ok, lua} = GenServer.call(holder, :checkout)

    lua =
      Lua.set!(lua, [:stop_holder], fn _, state ->
        Session.stop(holder)
        {[], state}
      end)

    :ok = GenServer.call(holder, {:commit, lua})
    assert {:error, %Error{code: {:command, :crashed}}} = Session.eval(holder, "stop_holder()", %{})
    refute Process.alive?(holder)
  end

  test "failed output callbacks do not commit changed globals", %{workspace: workspace} do
    lua = Lua.new() |> Lua.load_api(JidoApi) |> JidoApi.install_globals()
    {:ok, holder} = Session.new(lua)
    on_exit(fn -> Session.stop(holder) end)

    for emit <- [fn _ -> raise "output failed" end, fn _ -> throw(:output_failed) end] do
      context = %{workspace_id: workspace, cwd: "/", env: %{}, emit: emit}
      assert {:error, %Error{}} = Session.eval(holder, "value = 2; print(value)", context)
      {:ok, unchanged} = GenServer.call(holder, :checkout)
      assert {[nil], _} = Lua.eval!(unchanged, "return value")
    end
  end

  defp await_worker(worker) do
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1000
  end
end
