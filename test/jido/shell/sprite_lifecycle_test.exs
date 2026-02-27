defmodule Jido.Shell.SpriteLifecycleTest do
  use ExUnit.Case, async: true

  alias Jido.Shell.SpriteLifecycle

  defmodule FakeSessionMod do
    def start_with_vfs(workspace_id, opts) do
      send(self(), {:start_with_vfs, workspace_id, opts})
      Process.get(:sprite_start_result, {:ok, "sess-default"})
    end
  end

  defmodule FakeAgentMod do
    def run(session_id, command, opts) do
      send(self(), {:agent_run, session_id, command, opts})
      Process.get(:sprite_agent_run_result, {:ok, "ok\n"})
    end

    def stop(session_id) do
      send(self(), {:agent_stop, session_id})
      Process.get(:sprite_agent_stop_result, :ok)
    end
  end

  defmodule FakeSpritesMod do
    def new(token, opts) do
      send(self(), {:sprites_new, token, opts})
      {:client, token, opts}
    end

    def get_sprite(client, sprite_name) do
      send(self(), {:get_sprite_called, client, sprite_name})
      shift({:sprites_get_script, __MODULE__}, {:error, :not_found})
    end

    def sprite(client, sprite_name) do
      send(self(), {:sprite_called, client, sprite_name})
      {:sprite, client, sprite_name}
    end

    def destroy(sprite) do
      send(self(), {:destroy_called, sprite})
      shift({:sprites_destroy_script, __MODULE__}, :ok)
    end

    defp shift(key, default) do
      case Process.get(key, default) do
        [head | tail] ->
          Process.put(key, tail)
          head

        value ->
          value
      end
    end
  end

  defmodule FakeSpritesNoGet do
    def new(token, opts), do: {:client, token, opts}
  end

  defmodule FakeSpritesNoDestroy do
    def new(token, opts), do: {:client, token, opts}

    def get_sprite(_client, _sprite_name) do
      shift({:sprites_get_script, __MODULE__}, {:ok, %{id: "sprite"}})
    end

    def sprite(client, sprite_name), do: {:sprite, client, sprite_name}

    defp shift(key, default) do
      case Process.get(key, default) do
        [head | tail] ->
          Process.put(key, tail)
          head

        value ->
          value
      end
    end
  end

  test "provision/3 starts sprite session and prepares workspace directory" do
    Process.put(:sprite_start_result, {:ok, "sess-123"})
    Process.put(:sprite_agent_run_result, {:ok, "created\n"})

    sprite_config = %{
      "token" => "token-123",
      "create" => false,
      "base_url" => "https://sprites.example",
      "env" => %{"MODE" => "test"}
    }

    assert {:ok, result} =
             SpriteLifecycle.provision(
               "workspace-1",
               sprite_config,
               session_mod: FakeSessionMod,
               agent_mod: FakeAgentMod
             )

    assert result == %{
             session_id: "sess-123",
             sprite_name: "workspace-1",
             workspace_dir: "/work/workspace-1",
             workspace_id: "workspace-1"
           }

    assert_receive {:start_with_vfs, "workspace-1", session_opts}

    assert {Jido.Shell.Backend.Sprite,
            %{sprite_name: "workspace-1", token: "token-123", create: false, base_url: "https://sprites.example"}} =
             Keyword.fetch!(session_opts, :backend)

    assert Keyword.fetch!(session_opts, :env) == %{"MODE" => "test"}

    assert_receive {:agent_run, "sess-123", "mkdir -p /work/workspace-1", [timeout: 30_000]}
  end

  test "provision/3 honors overrides and returns mkdir errors" do
    Process.put(:sprite_start_result, {:ok, "sess-override"})
    Process.put(:sprite_agent_run_result, {:error, :mkdir_failed})

    assert {:error, :mkdir_failed} =
             SpriteLifecycle.provision(
               "workspace-2",
               %{token: "token-override", base_url: "   "},
               session_mod: FakeSessionMod,
               agent_mod: FakeAgentMod,
               workspace_base: "/tmp/work",
               workspace_dir: "/custom/ws",
               sprite_name: "sprite-override",
               timeout: 99
             )

    assert_receive {:start_with_vfs, "workspace-2", session_opts}

    assert {Jido.Shell.Backend.Sprite, %{sprite_name: "sprite-override", token: "token-override", create: true}} =
             Keyword.fetch!(session_opts, :backend)

    assert_receive {:agent_run, "sess-override", "mkdir -p /custom/ws", [timeout: 99]}
  end

  test "provision/3 propagates session startup errors" do
    Process.put(:sprite_start_result, {:error, :session_failed})

    assert {:error, :session_failed} =
             SpriteLifecycle.provision(
               "workspace-3",
               %{token: "token"},
               session_mod: FakeSessionMod,
               agent_mod: FakeAgentMod
             )

    refute_receive {:agent_run, _, _, _}, 20
  end

  test "teardown/2 verifies absent sprites immediately" do
    Process.put(:sprite_agent_stop_result, :ok)
    Process.put({:sprites_get_script, FakeSpritesMod}, [{:error, :not_found}])

    assert %{teardown_verified: true, teardown_attempts: 1, warnings: nil} =
             SpriteLifecycle.teardown(
               "sess-t1",
               sprite_name: "sprite-1",
               stop_mod: FakeAgentMod,
               sprite_config: %{token: "token"},
               sprites_mod: FakeSpritesMod,
               retry_backoffs_ms: [0, 0]
             )

    assert_receive {:agent_stop, "sess-t1"}
    assert_receive {:sprites_new, "token", []}
    assert_receive {:get_sprite_called, {:client, "token", []}, "sprite-1"}
    refute_receive {:destroy_called, _}, 20
  end

  test "teardown/2 destroys present sprites and verifies removal" do
    Process.put(:sprite_agent_stop_result, :ok)

    Process.put({:sprites_get_script, FakeSpritesMod}, [
      {:ok, %{id: "sprite-2"}},
      {:error, %{status: 404}}
    ])

    Process.put({:sprites_destroy_script, FakeSpritesMod}, [:ok])

    assert %{teardown_verified: true, teardown_attempts: 1, warnings: nil} =
             SpriteLifecycle.teardown(
               "sess-t2",
               sprite_name: "sprite-2",
               stop_mod: FakeAgentMod,
               sprite_config: %{token: "token"},
               sprites_mod: FakeSpritesMod,
               retry_backoffs_ms: [0]
             )

    assert_receive {:destroy_called, {:sprite, {:client, "token", []}, "sprite-2"}}
  end

  test "teardown/2 retries and reports warnings when verification never succeeds" do
    Process.put(:sprite_agent_stop_result, {:error, :already_stopped})

    Process.put({:sprites_get_script, FakeSpritesMod}, [
      {:ok, %{id: "sprite-3"}},
      {:ok, %{id: "sprite-3"}},
      {:ok, %{id: "sprite-3"}},
      {:ok, %{id: "sprite-3"}}
    ])

    Process.put({:sprites_destroy_script, FakeSpritesMod}, [
      {:error, :denied},
      {:error, :still_denied}
    ])

    result =
      SpriteLifecycle.teardown(
        "sess-t3",
        sprite_name: "sprite-3",
        stop_mod: FakeAgentMod,
        sprite_config: %{token: "token"},
        sprites_mod: FakeSpritesMod,
        retry_backoffs_ms: [0, 0]
      )

    assert result.teardown_verified == false
    assert result.teardown_attempts == 2
    assert_warning_contains(result.warnings, "session_stop_failed={:error, :already_stopped}")
    assert_warning_contains(result.warnings, "sprite_destroy_failed={:error, :denied}")
    assert_warning_contains(result.warnings, "sprite_destroy_failed={:error, :still_denied}")
    assert_warning_contains(result.warnings, "sprite teardown not verified after retries")
  end

  test "teardown/2 reports missing sprite name" do
    Process.put(:sprite_agent_stop_result, :ok)

    result =
      SpriteLifecycle.teardown(
        "sess-t4",
        sprite_name: nil,
        stop_mod: FakeAgentMod,
        sprites_mod: FakeSpritesMod,
        retry_backoffs_ms: [0]
      )

    assert result.teardown_verified == false
    assert result.teardown_attempts == 1
    assert_warning_contains(result.warnings, "sprite_verification_failed=:missing_sprite_name")
  end

  test "teardown/2 reports missing sprites client when token is blank" do
    Process.put(:sprite_agent_stop_result, :ok)

    result =
      SpriteLifecycle.teardown(
        "sess-t5",
        sprite_name: "sprite-5",
        stop_mod: FakeAgentMod,
        sprite_config: %{token: "   "},
        sprites_mod: FakeSpritesMod,
        retry_backoffs_ms: [0]
      )

    assert result.teardown_verified == false
    assert_warning_contains(result.warnings, "sprite_verification_failed=:missing_sprites_client")
  end

  test "teardown/2 reports missing get_sprite API" do
    Process.put(:sprite_agent_stop_result, :ok)

    result =
      SpriteLifecycle.teardown(
        "sess-t6",
        sprite_name: "sprite-6",
        stop_mod: FakeAgentMod,
        sprite_config: %{token: "token"},
        sprites_mod: FakeSpritesNoGet,
        retry_backoffs_ms: [0]
      )

    assert result.teardown_verified == false
    assert_warning_contains(result.warnings, "sprite_verification_failed=:missing_get_sprite_api")
  end

  test "teardown/2 reports missing destroy API" do
    Process.put(:sprite_agent_stop_result, :ok)

    Process.put({:sprites_get_script, FakeSpritesNoDestroy}, [
      {:ok, %{id: "sprite-7"}},
      {:ok, %{id: "sprite-7"}}
    ])

    result =
      SpriteLifecycle.teardown(
        "sess-t7",
        sprite_name: "sprite-7",
        stop_mod: FakeAgentMod,
        sprite_config: %{token: "token"},
        sprites_mod: FakeSpritesNoDestroy,
        retry_backoffs_ms: [0]
      )

    assert result.teardown_verified == false
    assert_warning_contains(result.warnings, "sprite_destroy_failed={:error, :missing_destroy_api}")
  end

  defp assert_warning_contains(warnings, expected_fragment) do
    assert is_list(warnings)

    assert Enum.any?(warnings, fn warning ->
             String.contains?(warning, expected_fragment)
           end)
  end
end
