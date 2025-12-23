defmodule Kodo.Command.Cd do
  @moduledoc """
  Changes the current working directory.

  ## Usage

      cd [path]
      cd        # go to root
      cd /home  # absolute path
      cd ..     # relative path
  """

  @behaviour Kodo.Command

  @impl true
  def name, do: "cd"

  @impl true
  def summary, do: "Change working directory"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, _emit) do
    target =
      case args.args do
        [] -> "/"
        [path | _] -> resolve_path(state.cwd, path)
      end

    case Kodo.VFS.stat(state.workspace_id, target) do
      {:ok, %Depot.Stat.Dir{}} ->
        {:ok, {:state_update, %{cwd: target}}}

      {:ok, _} ->
        {:error, Kodo.Error.vfs(:not_a_directory, target)}

      {:error, %Kodo.Error{code: {:vfs, :not_found}}} ->
        {:error, Kodo.Error.vfs(:not_found, target)}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_path(_cwd, "/" <> _ = path), do: Path.expand(path)
  defp resolve_path(cwd, path), do: Path.join(cwd, path) |> Path.expand()
end
