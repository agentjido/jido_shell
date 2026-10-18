defmodule Jido.Shell.Backend.LocalContractTest do
  use ExUnit.Case, async: true
  alias Jido.Shell.Backend.Local
  alias Jido.Shell.Error
  alias Jido.Shell.ShellSession.State

  test "initialization and execution require a session owner and session state" do
    assert {:error, %Error{code: {:session, :invalid_state_transition}}} = Local.init(%{})
    {:ok, backend} = Local.init(%{session_pid: self()})
    assert {:error, %Error{code: {:command, :start_failed}}} = Local.execute(backend, "pwd", [], [])
    assert {:ok, "/", ^backend} = Local.cwd(backend)
    assert {:ok, %{cwd: "/changed"}} = Local.cd(backend, "/changed")
    assert {:ok, ^backend} = Local.configure_network(backend, %{})
    assert :ok = Local.terminate(backend)
    assert {:error, :invalid_command_ref} = Local.cancel(backend, :invalid)
    assert :ok = Local.cancel(backend, self())
  end

  test "per-command directory and environment overrides leave the session state unchanged" do
    {:ok, backend} = Local.init(%{session_pid: self()})

    session =
      State.new!(%{
        id: "local-contract",
        workspace_id: "local-contract",
        cwd: "/original",
        env: %{"MODE" => "original"}
      })

    assert {:ok, worker, ^backend} =
             Local.execute(backend, "pwd", [], session_state: session, dir: "/override", env: %{"MODE" => "override"})

    assert_receive {:command_event, {:output, "/override\n"}}, 2000
    assert_receive {:command_finished, {:ok, _}}, 2000
    await_worker(worker)
    assert session.cwd == "/original"
    assert session.env == %{"MODE" => "original"}

    assert {:ok, worker, _} =
             Local.execute(backend, "env", ["MODE"], session_state: session, dir: :invalid, env: :invalid)

    assert_receive {:command_event, {:output, "MODE=original\n"}}, 2000
    assert_receive {:command_finished, {:ok, _}}, 2000
    await_worker(worker)
  end

  defp await_worker(worker) do
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1000
  end
end
