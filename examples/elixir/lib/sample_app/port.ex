defmodule SampleApp.Port do
  @moduledoc """
  Minimal Elixir wrapper for the native AtomVM port driver (`sample_app_port`).

  Protocol:

  - Request: `<<opcode::8, payload::binary>>`
  - Reply:
    - success: `<<0x00, payload::binary>>`
    - error:   `<<0x01, code::8>>`

  Opcodes:

  - `0x01` Ping: expects `<<"PONG">>`
  - `0x02` Echo: returns the payload unchanged
  """

  @compile {:no_warn_undefined, :port}

  # Must match the port driver name registered in the firmware (C side).
  @port_name "sample_app_port"

  @op_ping 0x01
  @op_echo 0x02

  def open() do
    :erlang.open_port({:spawn, @port_name}, [:binary])
  end

  def ping(port) do
    case :port.call(port, <<@op_ping>>) do
      <<0x00, "PONG">> ->
        :ok

      <<0x01, code>> ->
        {:error, {:driver_error, code}}

      other ->
        {:error, {:unexpected_reply, other}}
    end
  end

  def echo(port, payload) when is_binary(payload) do
    case :port.call(port, <<@op_echo, payload::binary>>) do
      <<0x00, echoed::binary>> ->
        {:ok, echoed}

      <<0x01, code>> ->
        {:error, {:driver_error, code}}

      other ->
        {:error, {:unexpected_reply, other}}
    end
  end
end
