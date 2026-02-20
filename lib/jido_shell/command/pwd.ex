defmodule Jido.Shell.Command.Pwd do
  @moduledoc """
  Prints the current working directory.

  ## Usage

      pwd
  """

  @behaviour Jido.Shell.Command

  @impl true
  def name, do: "pwd"

  @impl true
  def summary, do: "Print working directory"

  @impl true
  def schema do
    Zoi.map(%{
      args: Zoi.array(Zoi.string()) |> Zoi.default([])
    })
  end

  @impl true
  def run(state, _args, emit) do
    emit.({:output, state.cwd <> "\n"})
    {:ok, nil}
  end
end
