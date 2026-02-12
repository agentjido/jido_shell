defmodule Jido.Shell.Command.Ls do
  @moduledoc """
  Lists directory contents.
  """

  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "ls"

  @impl true
  def summary, do: "List directory contents"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, args, emit) do
    path =
      case args.args do
        [] -> state.cwd
        [p | _] -> resolve_path(state.cwd, p)
      end

    case Jido.Shell.VFS.list_dir(state.workspace_id, path) do
      {:ok, entries} ->
        output =
          entries
          |> Enum.map(&format_entry/1)
          |> Enum.join("\n")

        if output != "" do
          emit.({:output, output <> "\n"})
        end

        {:ok, entries}

      {:error, _} = error ->
        error
    end
  end

  defp format_entry(%Jido.VFS.Stat.Dir{name: name}), do: name <> "/"
  defp format_entry(%{name: name}), do: name

  defp resolve_path(cwd, path) do
    if String.starts_with?(path, "/") do
      path
    else
      Path.join(cwd, path) |> Path.expand()
    end
  end
end
