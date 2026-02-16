defmodule Jido.Shell.Command.Cd do
  @moduledoc """
  Changes the current working directory.

  ## Usage

      cd [path]
      cd        # go to root
      cd /home  # absolute path
      cd ..     # relative path
  """

  @behaviour Jido.Shell.Command

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

    case Jido.Shell.VFS.stat(state.workspace_id, target) do
      {:ok, %Jido.VFS.Stat.Dir{}} ->
        {:ok, {:state_update, %{cwd: target}}}

      {:ok, _} ->
        {:error, Jido.Shell.Error.vfs(:not_a_directory, target)}

      {:error, %Jido.Shell.Error{code: {:vfs, :not_found}}} ->
        {:error, Jido.Shell.Error.vfs(:not_found, target)}

      {:error, _} = error ->
        error
    end
  end

  defp resolve_path(_cwd, "/" <> _ = path), do: Path.expand(path)
  defp resolve_path(cwd, path), do: Path.join(cwd, path) |> Path.expand()
end
