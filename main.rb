require 'json'
require 'socket'

server_host = ARGV[0]
server_port = ARGV[1]
bot_name = ARGV[2]
bot_key = ARGV[3]

puts "I'm #{bot_name} and connect to #{server_host}:#{server_port}"

class NoobBot
  def initialize(server_host, server_port, bot_name, bot_key)
    tcp = TCPSocket.open(server_host, server_port)
    play(bot_name, bot_key, tcp)
  end

  @track       = nil  # All pieces in a track
  @lane_count  = nil  # Lanes in a track
  @lap_count   = nil  # Laps in a track
  @finish_line = nil  # Pieces that are on finish line
  @start_line  = nil  # Pieces that are on start line
  @turbo       = {}   # Is turbo available
  @friction    = nil  # Friction
  @fraction    = nil
  @switch      = []   # Lane switches

  private

  def play(bot_name, bot_key, tcp)
    tcp.puts join_message_2(bot_name, bot_key)
    react_to_messages_from_server tcp
  end

  def react_to_messages_from_server(tcp)
    gameTick        = nil
    lap             = nil # Current laps
    piece_idx       = nil # Current piece
    car             = nil # My car

    start_pos = nil
    stop_pos  = nil

    while json = tcp.gets
      message = JSON.parse(json)
      msgType = message['msgType']
      msgData = message['data']

      case msgType
        when 'carPositions'
          # Check for tick
          if message['gameTick']
            gameTick = message['gameTick']
          end

          msgData.each do |pos|
            # Check that car is ours
            if pos['id']['color'] == car && gameTick
              # Lap and current piece
              lap           = pos['piecePosition']['lap']
              piece_idx     = pos['piecePosition']['pieceIndex']
              in_piece_dist = pos['piecePosition']['inPieceDistance']
              lane          = pos['piecePosition']['lane']['startLaneIndex']
              car_angle     = pos['angle']

              if !start_pos
                start_pos = pos['piecePosition']['inPieceDistance']
              end

              # 10 ticks so we can make calculations now
              # Could be done with 2 ticks too, i guess
              if gameTick == 11
                stop_pos = pos['piecePosition']['inPieceDistance']
              end

              # Make calculations
              if start_pos && stop_pos && !@friction
                get_friction(start_pos, stop_pos)
              end

              # Calculate speed
              speed      = get_speed(piece_idx, car_angle, lap, gameTick)
              speed      = esp(speed, car_angle)
              data       = {:lap => lap, :car => car, :piece_idx => piece_idx, :lane => lane, :in_piece_dist => in_piece_dist, :car_positions => msgData}
              switch_dir = switch_lane(data, gameTick)

              if speed <= 0 then speed = 0.2 end

              # Throttle
              if @turbo[gameTick.to_i] && on_finish_line(lap, piece_idx)
                tcp.puts turbo_message(gameTick)
              elsif switch_dir
                tcp.puts switch_message(switch_dir, gameTick)
              else
                tcp.puts throttle_message(speed, gameTick)
              end
            end
          end
        else
          case msgType
            when 'join'
              puts 'Joined'
            when 'yourCar'
              car = msgData['color']
            when 'gameInit'
              # Get track data
              @track = msgData['race']['track']['pieces']
              @lane_count = msgData['race']['track']['lanes'].length

              # Get lap count it it's available
              if msgData['race']['raceSession']['laps']
                @lap_count = msgData['race']['raceSession']['laps']
              else
                @lap_count = nil
              end

              # Loop through track reversed and get which pieces form finish line
              straight_count = 0
              @track.reverse_each do |p|
                if !p.has_key?('angle')
                  straight_count += 1
                else
                  break
                end
              end
              @finish_line = @track.length - straight_count

              # Loop through track and get which pieces form starting line
              straight_count = 0
              @track.each do |p|
                if !p.has_key?('angle')
                  straight_count += 1
                else
                  break
                end
              end
              @start_line = straight_count

            when 'gameStart'
              puts 'Race started'
            when 'crash'
              if msgData['color'] == car
                puts "we crashed"
              end
            when 'turboAvailable'
              for turboTick in gameTick..gameTick+msgData['turboDurationTicks'] do
                @turbo[turboTick] = true
              end
            when 'gameEnd'
              puts 'Race ended'
            when 'error'
              puts "ERROR: #{msgData}"
            when 'lapFinished'
              @switch = []
          end
          puts "Got #{msgType}"
          tcp.puts ping_message
      end
    end
  end

  # Own functions
  def pint(json, exit_after = false)
    puts JSON.pretty_generate(json)
    if exit_after then exit end
  end

  # Brake if car angle is too big
  def esp(speed, car_angle)
    factors = {'0.1' => 65, '0.2' => 75, '0.3' => 85}
    if car_angle.abs >= 25
      return speed -= speed * (car_angle.abs / factors[@friction.round(1).to_s])
    else
      return speed
    end
  end

  # Check if we are on the finish line
  def on_finish_line(lap, piece_idx)
    if @lap_count
      return lap == @lap_count - 1 && piece_idx >= @finish_line
    else
      return piece_idx >= @finish_line
    end
  end

  # Check if we are in a first corner of the race
  def not_first_corner(lap, piece_idx)
    return (lap == 0 && piece_idx > @start_line) || lap > 0
  end

  # Are two vars same sign
  def same_sign(a, b)
    return a.to_i^b.to_i >= 0
  end

  # Calculate game friction, super scientific way!
  def get_friction(start_pos, stop_pos)
    # 10 gameticks
    duration = 10 * (1.0/60.0)

    # These probably make no sense
    velocity = (stop_pos - start_pos) / duration
    acceleration = velocity/duration
    friction = ((velocity**2)/(9.8*50))/10

    # Allow only frictions under 0.4 :)
    # Again, super scientific
    if friction.round(1) >= 0.4
      if friction.round(1) >= 0.7
        friction -= 0.6
      else
        friction -= 0.3
      end
    end
    if friction < 0.1
      friction += 0.1
    end

    @friction = friction
    puts "#{friction.round(3)}"
  end

  # Calculate speed for each gametick
  def get_speed(piece_idx, car_angle, lap, gameTick)
    speed = 1.0

    # Get current piece
    p_current = @track[piece_idx]

    # Get previous pieces
    p_prev = []
    j = @track.length - 1
    for i in 1..4
      if @track[piece_idx - i]
        p_prev << @track[piece_idx - i]
      else
        p_prev << @track[j]
        j -= 1
      end
    end

    # Calculate how many straights have we been passing since last curve
    straight = p_current.has_key?('length') ? 1 : 0
    p_prev.each do |p|
      if p.has_key?('length')
        straight += 1
      else
        if p['angle'].abs <= 22.5
          straight += 1
        end
      end
    end

    # Get n next pieces
    p_next = []
    j = 0
    for i in 1..3
      if @track[piece_idx + i]
        # If next piece exists, use it
        p_next << @track[piece_idx + i]
      else
        # No next piece so this must be the end of track, take piece from start
        p_next << @track[j]
        j += 1
      end
    end

    # Static brakes for each kind of curve
    # Hard-coded brake values for kind of curve
    # Not working that great
    if !@friction
      brakes = {
        50 => {
          22.5 => 0.15,
          45.0 => 0.20
        },
        100 => {
          22.5 => 0.125,
          45.0 => 0.2
        },
        200 => {
          22.5 => 0.05,
          45.0 => 0.15
        }
      }
    else
      fraction = 0.01 / @friction
      fraction += 0.01
      @fraction = fraction

      brakes = {
        50 => {
          22.5 => fraction * @friction * 5,
          45.0 => fraction * @friction * 17
        },
        100 => {
          22.5 => fraction * @friction * 4,
          45.0 => fraction * @friction * 17
        },
        200 => {
          22.5 => fraction * @friction * 3,
          45.0 => fraction * @friction * 8
        }
      }
    end

    brake_counts = {}
    # Check next pieces
    p_next.each_with_index do |p,i|
      # Next piece has curve so we need brakes
      if p.has_key?('angle')
        # Check if we have already used brake for this kinda curve
        brake_counts[p['angle'].abs] = !brake_counts[p['angle'].abs] ? 1.0 : brake_counts[p['angle'].abs] += 1.0
        if brake_counts[p['angle'].abs] > 1
          # Brake for this kind of curve has been used, use only 2/3 of brake force
          # since we probably don't need full brake anymore
          speed -= (brakes[p['radius']][p['angle'].abs] / 3.0) * 2.0
        else
          speed -= brakes[p['radius']][p['angle'].abs]
        end
      end
    end

    # If in a long straight, not in a first corner and with enough speed, brake before curve
    # Dirty solution for crashing in curves after long straights
    if straight >= 3 && not_first_corner(lap, piece_idx) && speed.round(2) < (1 - 3*brakes[200][22.5])
      for i in 0..1 do
        if p_next[i].has_key?('angle')
          speed -= (speed * p_next[i]['angle'].abs / 200.0) + 0.125
          break
        end
      end
    end

    # If we are on finish line, always max speed since no way of crashing anymore
    if on_finish_line(lap, piece_idx) then return 1.0 else return speed end
  end

  # Decide whether we should switch lanes and if so, where
  def switch_lane(data, gameTick)
    lane = data[:lane]

    # Get n next pieces
    p_next = []
    j = 0
    for i in 1..1
      if @track[data[:piece_idx] + i]
        p_next << @track[data[:piece_idx] + i]
      else
        p_next << @track[j]
        j += 1
      end
    end

    # No switch in the next piece
    if !p_next[0].has_key?('switch')
      return false
    end

    # If switch decision has already been made
    if @switch[data[:piece_idx]]
      return false
    end

    # Calculate total sum of angles for next pieces
    angle_sum = 0.0
    p_next.each do |p|
      if p.has_key?('angle')
        angle_sum+= p['angle']
      end
    end

    # Angle sum > 0 means curve(s) bend to right. Always switch to inner curve
    if angle_sum > 0
      lane_switch = 'Right'
      data[:target_lane] = lane - 1
    else
      lane_switch = 'Left'
      data[:target_lane] = lane + 1
    end

    # Check if current lane is blocked
    if lane_blocked(data, gameTick)
      # Switch current switch dir
      lane_switch = (lane_switch == 'Left') ? 'Right' : 'Left'
    else
      # Do not switch if we are currently blocking someone :)
      if blocking(data, gameTick)
        return false
      end
    end

    # Check that lane switch can actually be executed, eg. we are not switching to left in the leftmost lane.
    # This does not work well if lanes > 2
    if (lane_switch == 'Left' && lane == 0) || (lane_switch == 'Right' && lane == @lane_count -1)
      return false
    end

    @switch[data[:piece_idx]] = true
    return lane_switch
  end

  # Check if we are blocked by someone
  def lane_blocked(data, gameTick)
    ahead_count = 0
    data[:car_positions].each do |p|
      # No need to process our car
      if p['id']['color'] == data[:car]
        next
      end

      # If player is not in both, our current and our target lane, no need to process further
      if p['piecePosition']['lane']['startLaneIndex'] != data[:lane] && p['piecePosition']['lane']['startLaneIndex'] != data[:target_lane]
        next
      end

      # Do not process if player is not in our lap
      if p['piecePosition']['lap'] != data[:lap]
        next
      end

      # Check only 2 pieces ahead
      if p['piecePosition']['pieceIndex'] > data[:piece_idx] + 2
        next
      end

      # Check if there is someone ahead of us
      if p['piecePosition']['pieceIndex'] > data[:piece_idx]
        ahead_count += 1
      elsif p['piecePosition']['pieceIndex'] == data[:piece_idx] && p['piecePosition']['inPieceDistance'] > data[:in_piece_dist]
        ahead_count += 1
      end
    end

    return ahead_count > 0
  end

  # Check if we are currently blocking someone
  def blocking(data, gameTick)
    behind_count = 0
    data[:car_positions].each do |p|
      if p['id']['color'] == data[:car]
        next
      end

      if p['piecePosition']['lane']['startLaneIndex'] != data[:lane]
        next
      end

      if p['piecePosition']['lap'] != data[:lap]
        next
      end

      # Check only 2 pieces behind
      if p['piecePosition']['pieceIndex'] < data[:piece_idx] - 2
        next
      end

      # Check how many cars are behind us
      if p['piecePosition']['pieceIndex'] < data[:piece_idx]
        behind_count += 1
      elsif p['piecePosition']['pieceIndex'] == data[:piece_idx] && p['piecePosition']['inPieceDistance'] < data[:in_piece_dist]
        behind_count += 1
      end
    end

    return behind_count > 0
  end
  # End of own functions

  def join_message(bot_name, bot_key)
    make_msg("join", {:name => bot_name, :key => bot_key})
  end

  def throttle_message(throttle, gameTick)
    make_msg("throttle", throttle, gameTick)
  end

  def turbo_message(gameTick)
    make_msg("turbo", "NY RILLATAA!", gameTick)
  end

  def switch_message(lane, gameTick)
    make_msg("switchLane", lane, gameTick)
  end

  def ping_message
    make_msg("ping", {})
  end

  def make_msg(msgType, data, gameTick = nil)
    if gameTick
      JSON.generate({:msgType => msgType, :data => data, :gameTick => gameTick})
    else
      JSON.generate({:msgType => msgType, :data => data})
    end
  end
end

NoobBot.new(server_host, server_port, bot_name, bot_key)
