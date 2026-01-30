defmodule SampleApp.Port do
  @moduledoc false

  @compile {:no_warn_undefined, :port}

  @driver ~c"sample_app_port"

  def open() do
    :erlang.open_port({:spawn_driver, @driver}, [:binary])
  end

  def ping(port), do: call(port, 0x01)
  def echo(port, payload) when is_binary(payload), do: call(port, 0x02, payload)

  def ble_start(port), do: call(port, 0x10)
  def ble_stop(port), do: call(port, 0x11)

  def latest(port), do: call(port, 0x12)

  def latest_for_id(port, id) when is_integer(id) and id in 0..0xFFFF do
    call(port, 0x13, <<id::16-big>>)
  end

  defp call(port, opcode, payload \\ <<>>) do
    req = <<opcode, payload::binary>>

    case :port.call(port, req) do
      <<0x00, rest::binary>> -> {:ok, rest}
      <<0x01, code>> -> {:error, {:driver_error, code}}
      other -> {:error, {:bad_reply, other}}
    end
  end
end
