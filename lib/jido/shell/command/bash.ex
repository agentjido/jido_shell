defmodule Jido.Shell.Command.Bash do
  @moduledoc """
  Executes bash-like scripts in the Jido.Shell sandbox.

  Scripts are executed through Jido.Shell commands (not the host shell).

  ## Usage

      bash -c "mkdir docs; write docs/hello.txt hello; cat docs/hello.txt"
      bash /scripts/setup.sh
  """

  @behaviour Jido.Shell.Command

  alias Jido.Shell.Sandbox.Bash, as: BashSandbox

  @impl true
  def name, do: "bash"

  @impl true
  def summary, do: "Run a bash-like script in the shell sandbox"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, emit) do
    with {:ok, script} <- load_script(state, args.args),
         {:ok, final_state} <- BashSandbox.execute(state, script, emit) do
      to_state_update(state, final_state)
    end
  end

  defp load_script(_state, []),
    do: {:error, Jido.Shell.Error.validation("bash", [%{message: "usage: bash -c \"<script>\" | bash <file>"}])}

  defp load_script(_state, ["-c"]),
    do: {:error, Jido.Shell.Error.validation("bash", [%{message: "usage: bash -c \"<script>\" | bash <file>"}])}

  defp load_script(_state, ["-c", script]), do: {:ok, script}

  defp load_script(_state, ["-c" | _]),
    do: {:error, Jido.Shell.Error.validation("bash", [%{message: "usage: bash -c \"<script>\" | bash <file>"}])}

  defp load_script(state, [path]) do
    path = resolve_path(state.cwd, path)
    Jido.Shell.VFS.read_file(state.workspace_id, path)
  end

  defp load_script(_state, _),
    do: {:error, Jido.Shell.Error.validation("bash", [%{message: "usage: bash -c \"<script>\" | bash <file>"}])}

  defp to_state_update(state, final_state) do
    state_update =
      %{}
      |> maybe_put(:cwd, state.cwd, final_state.cwd)
      |> maybe_put(:env, state.env, final_state.env)

    if map_size(state_update) == 0 do
      {:ok, nil}
    else
      {:ok, {:state_update, state_update}}
    end
  end

  defp maybe_put(acc, _key, left, right) when left == right, do: acc
  defp maybe_put(acc, key, _left, right), do: Map.put(acc, key, right)

  defp resolve_path(_cwd, "/" <> _ = path), do: Path.expand(path)
  defp resolve_path(cwd, path), do: Path.join(cwd, path) |> Path.expand()
end
