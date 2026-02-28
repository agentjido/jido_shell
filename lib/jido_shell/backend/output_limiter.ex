defmodule Jido.Shell.Backend.OutputLimiter do
  @moduledoc """
  Shared output-limit logic for SSH and Sprite backends.

  Tracks emitted bytes and aborts when the configured limit is exceeded.
  """

  alias Jido.Shell.Error

  @doc """
  Check whether emitting `chunk_bytes` would exceed `output_limit`.

  Returns `{:ok, updated_bytes}` when under the limit, or
  `{:limit_exceeded, %Jido.Shell.Error{}}` when the limit is breached.
  """
  @spec check(non_neg_integer(), non_neg_integer(), non_neg_integer() | nil) ::
          {:ok, non_neg_integer()} | {:limit_exceeded, Error.t()}
  def check(chunk_bytes, emitted_bytes, output_limit)
      when is_integer(chunk_bytes) and is_integer(emitted_bytes) do
    updated_total = emitted_bytes + chunk_bytes

    if is_integer(output_limit) and output_limit > 0 and updated_total > output_limit do
      {:limit_exceeded,
       Error.command(:output_limit_exceeded, %{
         emitted_bytes: updated_total,
         max_output_bytes: output_limit
       })}
    else
      {:ok, updated_total}
    end
  end
end
