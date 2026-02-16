defmodule Jido.Shell.Backend.SpriteTest do
  use Jido.Shell.Case, async: false

  alias Jido.Shell.Backend.Sprite

  defmodule FakeSprites do
    def client(token), do: client(token, [])

    def client(token, opts) do
      notify({:client, token, opts})
      {:ok, %{token: token, opts: opts}}
    end

    def create(client, name) do
      notify({:create, name})
      {:ok, %{client: client, name: name}}
    end

    def sprite(client, name) do
      notify({:sprite, name})
      {:ok, %{client: client, name: name}}
    end

    def destroy(_sprite) do
      notify(:destroy)
      :ok
    end

    def set_network_policy(_sprite, policy) do
      notify({:network_policy, policy})
      :ok
    end

    def spawn(_sprite, _cmd, ["-lc", line], _opts) do
      ref = make_ref()
      notify({:spawn, line})

      case line do
        "echo sprite" ->
          send(self(), {:stdout, ref, "sprite\n"})
          send(self(), {:exit, ref, 0})

        "fail sprite" ->
          send(self(), {:stderr, ref, "failed\n"})
          send(self(), {:exit, ref, 7})

        "limit sprite" ->
          send(self(), {:stdout, ref, "123456"})
          send(self(), {:exit, ref, 0})

        "sleep sprite" ->
          Process.send_after(self(), {:stdout, ref, "sleeping\n"}, 5)
          Process.send_after(self(), {:exit, ref, 0}, 250)

        _ ->
          send(self(), {:exit, ref, 0})
      end

      {:ok, ref}
    end

    def close_stdin(command_ref) do
      notify({:close_stdin, command_ref})
      :ok
    end

    def kill(command_ref) do
      notify({:kill, command_ref})
      :ok
    end

    def await(command_ref) do
      notify({:await, command_ref})
      :ok
    end

    defp notify(event) do
      case :persistent_term.get({__MODULE__, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:fake_sprites, event})
        _ -> :ok
      end
    end
  end

  setup do
    :persistent_term.put({FakeSprites, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({FakeSprites, :test_pid})
    end)

    :ok
  end

  test "init and terminate lifecycle with create: true" do
    {:ok, state} =
      Sprite.init(%{
        session_pid: self(),
        sprite_name: "sprite-test",
        token: "token",
        create: true,
        sprites_module: FakeSprites
      })

    assert_receive {:fake_sprites, {:client, "token", _}}
    assert_receive {:fake_sprites, {:create, "sprite-test"}}
    assert state.owns_sprite?

    assert :ok = Sprite.terminate(state)
    assert_receive {:fake_sprites, :destroy}
  end

  test "execute streams output and returns command_done payload" do
    {:ok, state} =
      Sprite.init(%{
        session_pid: self(),
        sprite_name: "sprite-test",
        token: "token",
        create: false,
        sprites_module: FakeSprites
      })

    {:ok, worker_pid, _state} = Sprite.execute(state, "echo sprite", [], [])
    assert is_pid(worker_pid)

    assert_receive {:command_event, {:output, "sprite\n"}}
    assert_receive {:command_finished, {:ok, nil}}

    ref = Process.monitor(worker_pid)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _}
  end

  test "execute maps non-zero exits to structured errors" do
    {:ok, state} =
      Sprite.init(%{
        session_pid: self(),
        sprite_name: "sprite-test",
        token: "token",
        sprites_module: FakeSprites
      })

    {:ok, _worker_pid, _state} = Sprite.execute(state, "fail sprite", [], [])

    assert_receive {:command_event, {:output, "failed\n"}}
    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :exit_code}}}}
  end

  test "execute enforces output limits" do
    {:ok, state} =
      Sprite.init(%{
        session_pid: self(),
        sprite_name: "sprite-test",
        token: "token",
        sprites_module: FakeSprites
      })

    {:ok, _worker_pid, _state} = Sprite.execute(state, "limit sprite", [], output_limit: 3)

    assert_receive {:command_finished, {:error, %Jido.Shell.Error{code: {:command, :output_limit_exceeded}}}}
  end

  test "cancel closes remote command and stops worker" do
    {:ok, state} =
      Sprite.init(%{
        session_pid: self(),
        sprite_name: "sprite-test",
        token: "token",
        sprites_module: FakeSprites
      })

    {:ok, worker_pid, _state} = Sprite.execute(state, "sleep sprite", [], [])
    assert_receive {:fake_sprites, {:spawn, "sleep sprite"}}

    assert :ok = Sprite.cancel(state, worker_pid)
    assert_receive {:fake_sprites, {:close_stdin, _}}
    assert_receive {:fake_sprites, {:kill, _}}
  end

  test "execute configures network policy from execution context" do
    {:ok, state} =
      Sprite.init(%{
        session_pid: self(),
        sprite_name: "sprite-test",
        token: "token",
        sprites_module: FakeSprites
      })

    {:ok, _worker_pid, _state} =
      Sprite.execute(
        state,
        "echo sprite",
        [],
        execution_context: %{network: %{allow_domains: ["example.com"], allow_ports: [443]}}
      )

    assert_receive {:fake_sprites, {:network_policy, policy}}
    assert policy.allow_domains == ["example.com"]
    assert policy.allow_ports == [443]
    assert_receive {:command_finished, {:ok, nil}}
  end

  @tag :sprites
  test "live Sprite execution (requires SPRITES_TOKEN)" do
    token = System.get_env("SPRITES_TOKEN") || System.get_env("SPRITE_TOKEN")

    if is_binary(token) and byte_size(String.trim(token)) > 0 do
      sprite_name = "jido-shell-test-#{System.unique_integer([:positive])}"

      {:ok, state} =
        Sprite.init(%{
          session_pid: self(),
          sprite_name: sprite_name,
          token: token,
          create: true
        })

      {:ok, _worker_pid, state} = Sprite.execute(state, "echo sprite-live", [], [])
      assert_receive {:command_event, {:output, output}}, 30_000
      assert output =~ "sprite-live"
      assert_receive {:command_finished, {:ok, nil}}, 30_000

      assert :ok = Sprite.terminate(state)
    else
      assert true
    end
  end
end
