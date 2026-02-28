defmodule Jido.Shell.Environment do
  @moduledoc """
  Behaviour for VM/infrastructure lifecycle management.

  An Environment handles provisioning and tearing down the infrastructure
  that a shell session runs on. After provisioning, the environment starts
  a shell session using the appropriate `Jido.Shell.Backend`.

  ## Two Concerns

  - **Backend** = command execution on a running machine (`Jido.Shell.Backend`)
  - **Environment** = VM lifecycle: provision, teardown, status (this behaviour)

  ## Implementations

  - `Jido.Shell.Environment.Sprite` — Fly.io Sprites
  - External packages can implement this for Hetzner, Scaleway, AWS, etc.

  ## Example

      defmodule MyApp.Environment.Hetzner do
        @behaviour Jido.Shell.Environment

        @impl true
        def provision(workspace_id, config, opts) do
          # 1. Create Hetzner VM via API
          # 2. Wait for ready, get IP
          # 3. Start session with Backend.SSH
          session_opts = [
            backend: {Jido.Shell.Backend.SSH, %{host: ip, user: "root", key: config.ssh_key}}
          ]
          {:ok, session_id} = Jido.Shell.ShellSession.start_with_vfs(workspace_id, session_opts)
          {:ok, %{session_id: session_id, workspace_dir: "/work", workspace_id: workspace_id}}
        end

        @impl true
        def teardown(session_id, _opts), do: %{teardown_verified: true, teardown_attempts: 1, warnings: nil}
      end

  """

  @typedoc """
  Result of a successful provision operation.

  Must include at minimum `session_id`, `workspace_dir`, and `workspace_id`.
  Implementations may add environment-specific metadata (e.g., `server_id`, `ip`).
  """
  @type provision_result :: %{
          :session_id => String.t(),
          :workspace_dir => String.t(),
          :workspace_id => String.t(),
          optional(:sprite_name) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "Result of a teardown operation."
  @type teardown_result :: %{
          teardown_verified: boolean(),
          teardown_attempts: pos_integer(),
          warnings: [String.t()] | nil
        }

  @doc """
  Provision infrastructure and start a shell session.

  Returns metadata including at minimum `session_id`, `workspace_dir`, and `workspace_id`.
  """
  @callback provision(workspace_id :: String.t(), config :: map(), opts :: keyword()) ::
              {:ok, provision_result()} | {:error, term()}

  @doc """
  Tear down infrastructure and stop the session.

  Returns teardown metadata with verification status.
  """
  @callback teardown(session_id :: String.t(), opts :: keyword()) :: teardown_result()

  @doc """
  Query the status of a provisioned environment.

  Optional — not all environments support status queries.
  """
  @callback status(session_id :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks status: 2
end
