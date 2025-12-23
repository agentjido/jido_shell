defmodule Kodo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Kodo.VFS.init()

    children = [
      {Registry, keys: :unique, name: Kodo.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: Kodo.SessionSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: Kodo.FilesystemSupervisor},
      {Task.Supervisor, name: Kodo.CommandTaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Kodo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
