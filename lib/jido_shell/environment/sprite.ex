defmodule Jido.Shell.Environment.Sprite do
  @moduledoc """
  Fly.io Sprite environment implementation.

  Provisions Sprite-backed shell sessions and handles teardown with
  retry-based verification. This is the default environment used by
  `Jido.Harness.Exec.Workspace`.
  """

  @behaviour Jido.Shell.Environment

  alias Jido.Shell.Exec

  @default_retry_backoffs_ms [0, 1_000, 3_000]

  @type provision_result :: %{
          session_id: String.t(),
          sprite_name: String.t(),
          workspace_dir: String.t(),
          workspace_id: String.t()
        }

  @type teardown_result :: %{
          teardown_verified: boolean(),
          teardown_attempts: pos_integer(),
          warnings: [String.t()] | nil
        }

  @impl true
  @spec provision(String.t(), map(), keyword()) :: {:ok, provision_result()} | {:error, term()}
  def provision(workspace_id, config, opts \\ [])
      when is_binary(workspace_id) and is_map(config) do
    workspace_base = Keyword.get(opts, :workspace_base, "/work")
    workspace_dir = Keyword.get(opts, :workspace_dir, "#{workspace_base}/#{workspace_id}")
    sprite_name = Keyword.get(opts, :sprite_name, workspace_id)
    timeout = Keyword.get(opts, :timeout, 30_000)
    session_mod = Keyword.get(opts, :session_mod, Jido.Shell.ShellSession)
    agent_mod = Keyword.get(opts, :agent_mod, Jido.Shell.Agent)

    backend_config =
      %{
        sprite_name: sprite_name,
        token: config_get(config, :token),
        create: config_get(config, :create, true)
      }
      |> maybe_put_base_url(config_get(config, :base_url))

    session_opts = [
      backend: {Jido.Shell.Backend.Sprite, backend_config},
      env: config_get(config, :env, %{})
    ]

    with {:ok, session_id} <- session_mod.start_with_vfs(workspace_id, session_opts),
         {:ok, _} <- Exec.run(agent_mod, session_id, "mkdir -p #{workspace_dir}", timeout: timeout) do
      {:ok,
       %{
         session_id: session_id,
         sprite_name: sprite_name,
         workspace_dir: workspace_dir,
         workspace_id: workspace_id
       }}
    end
  end

  @impl true
  @spec teardown(String.t(), keyword()) :: teardown_result()
  def teardown(session_id, opts \\ []) when is_binary(session_id) do
    sprite_name = Keyword.get(opts, :sprite_name)
    stop_mod = Keyword.get(opts, :stop_mod, Jido.Shell.Agent)
    sprite_config = Keyword.get(opts, :sprite_config)
    sprites_mod = Keyword.get(opts, :sprites_mod, Sprites)
    retry_backoffs_ms = Keyword.get(opts, :retry_backoffs_ms, @default_retry_backoffs_ms)
    client = build_client(sprite_config, sprites_mod)

    Enum.with_index(retry_backoffs_ms, 1)
    |> Enum.reduce_while(%{warnings: []}, fn {backoff_ms, attempt}, acc ->
      maybe_sleep(backoff_ms)

      warnings =
        acc.warnings
        |> maybe_add_warning(stop_session(stop_mod, session_id), "session_stop")

      case verify_and_destroy(sprite_name, client, sprites_mod, warnings) do
        {:verified, attempt_warnings} ->
          {:halt,
           %{
             teardown_verified: true,
             teardown_attempts: attempt,
             warnings: normalize_warnings(attempt_warnings)
           }}

        {:not_verified, attempt_warnings} ->
          {:cont, %{warnings: attempt_warnings}}
      end
    end)
    |> case do
      %{teardown_verified: _} = done ->
        done

      %{warnings: warnings} ->
        %{
          teardown_verified: false,
          teardown_attempts: length(retry_backoffs_ms),
          warnings:
            normalize_warnings([
              "sprite teardown not verified after retries"
              | warnings
            ])
        }
    end
  end

  defp maybe_sleep(ms) when is_integer(ms) and ms > 0, do: Process.sleep(ms)
  defp maybe_sleep(_), do: :ok

  defp stop_session(mod, session_id) do
    if supports?(mod, :stop, 1) do
      mod.stop(session_id)
    else
      Jido.Shell.Agent.stop(session_id)
    end
  end

  defp verify_and_destroy(sprite_name, client, sprites_mod, warnings) do
    case verify_absent(sprite_name, client, sprites_mod) do
      :absent ->
        {:verified, warnings}

      :present ->
        destroy_result = destroy_sprite(sprite_name, client, sprites_mod)

        warnings =
          warnings
          |> maybe_add_warning(destroy_result, "sprite_destroy")

        case verify_absent(sprite_name, client, sprites_mod) do
          :absent -> {:verified, warnings}
          :present -> {:not_verified, warnings}
          {:error, reason} -> {:not_verified, add_warning(warnings, verification_warning(reason))}
        end

      {:error, reason} ->
        {:not_verified, add_warning(warnings, verification_warning(reason))}
    end
  end

  defp verify_absent(nil, _client, _sprites_mod), do: {:error, :missing_sprite_name}
  defp verify_absent("", _client, _sprites_mod), do: {:error, :missing_sprite_name}
  defp verify_absent(_sprite_name, nil, _sprites_mod), do: {:error, :missing_sprites_client}

  defp verify_absent(sprite_name, client, sprites_mod) do
    if supports?(sprites_mod, :get_sprite, 2) do
      case sprites_mod.get_sprite(client, sprite_name) do
        {:ok, _sprite} ->
          :present

        {:error, reason} ->
          if not_found_reason?(reason), do: :absent, else: {:error, reason}
      end
    else
      {:error, :missing_get_sprite_api}
    end
  end

  defp destroy_sprite(nil, _client, _sprites_mod), do: {:error, :missing_sprite_name}
  defp destroy_sprite("", _client, _sprites_mod), do: {:error, :missing_sprite_name}
  defp destroy_sprite(_sprite_name, nil, _sprites_mod), do: {:error, :missing_sprites_client}

  defp destroy_sprite(sprite_name, client, sprites_mod) do
    with true <- supports?(sprites_mod, :sprite, 2),
         true <- supports?(sprites_mod, :destroy, 1) do
      sprite = sprites_mod.sprite(client, sprite_name)

      case sprites_mod.destroy(sprite) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_destroy_result, other}}
      end
    else
      _ -> {:error, :missing_destroy_api}
    end
  end

  defp build_client(sprite_config, sprites_mod)
       when is_map(sprite_config) and is_atom(sprites_mod) do
    token = config_get(sprite_config, :token)

    if is_binary(token) and String.trim(token) != "" and supports?(sprites_mod, :new, 2) do
      base_url = config_get(sprite_config, :base_url)

      opts =
        if is_binary(base_url) and String.trim(base_url) != "", do: [base_url: base_url], else: []

      sprites_mod.new(token, opts)
    else
      nil
    end
  end

  defp build_client(_, _), do: nil

  defp supports?(mod, fun, arity)
       when is_atom(mod) and is_atom(fun) and is_integer(arity) and arity >= 0 do
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  defp not_found_reason?(%{status: 404}), do: true
  defp not_found_reason?({:http_error, 404, _}), do: true
  defp not_found_reason?({:error, %{status: 404}}), do: true
  defp not_found_reason?(:not_found), do: true
  defp not_found_reason?({:not_found, _}), do: true

  defp not_found_reason?(reason) when is_binary(reason) do
    down = String.downcase(reason)
    String.contains?(down, "404") or String.contains?(down, "not found")
  end

  defp not_found_reason?(reason), do: String.contains?(inspect(reason), "404")

  defp maybe_add_warning(warnings, :ok, _prefix), do: warnings
  defp maybe_add_warning(warnings, {:ok, _}, _prefix), do: warnings

  defp maybe_add_warning(warnings, reason, prefix) do
    add_warning(warnings, "#{prefix}_failed=#{inspect(reason)}")
  end

  defp verification_warning(reason), do: "sprite_verification_failed=#{inspect(reason)}"

  defp add_warning(warnings, warning) when is_list(warnings) and is_binary(warning) do
    [warning | warnings]
  end

  defp normalize_warnings([]), do: nil

  defp normalize_warnings(warnings) when is_list(warnings) do
    warnings
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp maybe_put_base_url(config, nil), do: config

  defp maybe_put_base_url(config, base_url) when is_binary(base_url) do
    if String.trim(base_url) == "" do
      config
    else
      Map.put(config, :base_url, base_url)
    end
  end

  defp config_get(config, key, default \\ nil) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end
end
