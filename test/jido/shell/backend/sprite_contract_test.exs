defmodule Jido.Shell.Backend.SpriteContractTest do
  use ExUnit.Case, async: true
  alias Jido.Shell.Backend.Sprite
  alias Jido.Shell.Error

  defmodule StreamingClient do
    def new(_, opts), do: %{owner: self(), opts: opts}
    def sprite(client, name), do: Map.put(client, :name, name)
    def create(client, name), do: {:ok, sprite(client, name)}
    def destroy(sprite), do: send(sprite.owner, :destroyed)

    def set_network_policy(sprite, policy) do
      send(sprite.owner, {:policy, policy})
      if sprite.name == "policy-failure", do: {:error, :denied}, else: :ok
    end

    def network_policy(_, %{name: "policy-failure"}, _), do: {:error, :denied}

    def spawn(sprite, shell, args, opts) do
      send(sprite.owner, {:spawned, self(), shell, args, opts})
      ref = {sprite.owner, make_ref()}

      case sprite.name do
        "stderr-limit" -> send(self(), {:stderr, ref, "too large"})
        "closed" -> send(self(), {:error, ref, :closed})
        "normal" -> send(self(), {:error, ref, :normal})
        "stream-failure" -> send(self(), {:error, ref, :offline})
        "timeout" -> :ok
        "exception" -> raise "spawn failed"
        "throw" -> throw(:spawn_failed)
        _ -> send(self(), {:exit, ref, 0})
      end

      {:ok, ref}
    end

    def close_stdin({owner, _}), do: send(owner, :stdin_closed)
    def kill({owner, _}), do: send(owner, :remote_killed)
  end

  defmodule SyncClient do
    def client(_), do: %{owner: self()}
    def sprite(client, name), do: Map.put(client, :name, name)

    def cmd(sprite, _, _, _) do
      case sprite.name do
        "tuple" -> {"tuple output", 0}
        "map" -> %{output: "map output", exit_code: 0}
        "stdout" -> %{stdout: "stdout output", status: 0}
        "empty" -> {"", 0}
        "nil" -> {nil, 0}
        "exit" -> {"failed output", 7}
        "limit" -> {"too much", 0}
        "invalid" -> :invalid
      end
    end
  end

  defmodule FailedClient do
    def client(_, _), do: {:error, :offline}
    def new(_), do: {:error, :offline}
  end

  defmodule FailedConnect do
    def client(_), do: :client
    def sprite(_, _), do: {:error, :offline}
    def create(_, _), do: {:error, :offline}
  end

  test "initialization refuses missing values and client failures" do
    assert {:error, %Error{code: {:session, :invalid_state_transition}}} = Sprite.init(%{})

    for config <- [
          %{},
          %{sprite_name: " "},
          %{sprite_name: 123},
          %{sprite_name: "name"},
          %{sprite_name: "name", token: " "}
        ] do
      assert {:error, %Error{code: {:command, :start_failed}}} = Sprite.init(Map.put(config, :session_pid, self()))
    end

    assert {:error, :offline} =
             Sprite.init(%{session_pid: self(), sprite_name: "name", token: "token", sprites_module: FailedClient})

    for create <- [true, false] do
      assert {:error, %Error{code: {:command, :start_failed}}} =
               Sprite.init(%{
                 session_pid: self(),
                 sprite_name: "name",
                 token: "token",
                 sprites_module: FailedConnect,
                 create: create
               })
    end
  end

  test "synchronous clients preserve output, exit status, and output limits" do
    for {name, output} <- [{"tuple", "tuple output"}, {"map", "map output"}, {"stdout", "stdout output"}] do
      state = state(name, SyncClient)
      assert {:ok, worker, _} = Sprite.execute(state, "echo", ["argument"], [])
      assert_receive {:command_event, {:output, ^output}}, 2000
      assert_receive {:command_finished, {:ok, nil}}, 2000
      await_worker(worker)
      assert :ets.tab2list(state.commands_table) == []
    end

    for name <- ["nil", "empty"] do
      assert {:ok, worker, _} = Sprite.execute(state(name, SyncClient), "true", [], [])
      assert_receive {:command_finished, {:ok, nil}}, 2000
      await_worker(worker)
      refute_received {:command_event, _}
    end

    for {name, code} <- [{"exit", :exit_code}, {"invalid", :start_failed}, {"limit", :output_limit_exceeded}] do
      assert {:ok, worker, _} = Sprite.execute(state(name, SyncClient), "command", [], output_limit: 3)
      assert_receive {:command_finished, {:error, %Error{code: {:command, ^code}}}}, 2000
      await_worker(worker)
    end
  end

  test "stream closure, timeout, and errors finish the command and clean its registration" do
    for name <- ["closed", "normal"] do
      state = state(name)
      assert {:ok, worker, _} = Sprite.execute(state, "command", [], [])
      assert_receive {:command_finished, {:ok, nil}}, 2000
      await_worker(worker)
      assert :ets.tab2list(state.commands_table) == []
    end

    for {name, code} <- [
          {"stream-failure", :start_failed},
          {"exception", :start_failed},
          {"throw", :start_failed},
          {"timeout", :timeout},
          {"stderr-limit", :output_limit_exceeded}
        ] do
      state = state(name)
      assert {:ok, worker, _} = Sprite.execute(state, "command", [], timeout: 10, output_limit: 2)
      assert_receive {:command_finished, {:error, %Error{code: {:command, ^code}}}}, 1000
      await_worker(worker)
      assert :ets.tab2list(state.commands_table) == []

      if name in ["timeout", "stderr-limit"] do
        assert_received :stdin_closed
        assert_received :remote_killed
      end
    end
  end

  test "execution normalizes string limits, environment, and network options" do
    state = state("options")

    assert {:ok, worker, updated} =
             Sprite.execute(state, "echo", ["value"],
               dir: "/work",
               env: %{MODE: 123},
               execution_context: %{
                 "limits" => %{"max_runtime_ms" => "1000", "max_output_bytes" => "32"},
                 "network" => %{
                   "default" => "allow",
                   "allow_domains" => [" example.com ", "", "example.com"],
                   "allow_ports" => ["443", 443, "bad", -1, 70_000],
                   "block_ports" => ["0"]
                 }
               }
             )

    assert updated.cwd == "/work"
    assert updated.env == %{"MODE" => "123"}
    assert_receive {:spawned, ^worker, "sh", ["-lc", "echo value"], options}, 2000
    assert options[:timeout] == 1000
    assert options[:env] == [{"MODE", "123"}]
    assert options[:dir] == "/work"

    assert_receive {:policy, %{default: :allow, allow_domains: ["example.com"], allow_ports: [443], block_ports: [0]}},
                   2000

    assert_receive {:command_finished, {:ok, nil}}, 2000
    await_worker(worker)

    assert {:ok, worker, _} =
             Sprite.execute(updated, "true", [],
               execution_context: [
                 network: [default: :allow, allow_domains: ["example.com"], allow_ports: [443], block_ports: [0]]
               ]
             )

    assert_receive {:command_finished, {:ok, nil}}, 2000
    await_worker(worker)
    refute_received {:policy, _}
  end

  test "invalid limits and environments fall back to defaults" do
    for limits <- [
          %{max_runtime_ms: "bad", max_output_bytes: -1},
          %{max_runtime_ms: 0, max_output_bytes: "0"},
          :invalid
        ] do
      assert {:ok, worker, updated} =
               Sprite.execute(state("options"), "true", [], env: [:invalid], execution_context: %{limits: limits})

      assert updated.env == %{}
      assert_receive {:spawned, ^worker, _, _, options}, 2000
      refute Keyword.has_key?(options, :timeout)
      assert_receive {:command_finished, {:ok, nil}}, 2000
      await_worker(worker)
    end
  end

  test "network failures refuse execution and unsupported clients retain the selected policy" do
    assert {:error, %Error{code: {:command, :network_policy_failed}}} =
             Sprite.execute(state("policy-failure"), "true", [], execution_context: %{network: %{}})

    refute_received {:spawned, _, _, _, _}
    assert {:ok, updated} = Sprite.configure_network(state("tuple", SyncClient), %{default: :allow})
    assert updated.network_policy.default == :allow
  end

  test "cwd, cancellation, and repeated teardown preserve ownership" do
    state = state("options")
    assert {:ok, "/", ^state} = Sprite.cwd(state)
    assert {:ok, %{cwd: "/changed"}} = Sprite.cd(state, "/changed")
    assert {:error, :invalid_command_ref} = Sprite.cancel(state, :unknown)
    dead = spawn(fn -> :ok end)
    await_worker(dead)
    assert :ok = Sprite.cancel(state, dead)
    assert :ok = Sprite.terminate(state)
    assert :ok = Sprite.terminate(state)
    refute_received :destroyed
  end

  defp state(name, client \\ StreamingClient) do
    {:ok, state} =
      Sprite.init(%{
        session_pid: self(),
        sprite_name: name,
        token: "token",
        sprites_module: client,
        base_url: "https://example.test"
      })

    on_exit(fn -> Sprite.terminate(state) end)
    state
  end

  defp await_worker(worker) do
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1000
  end
end
