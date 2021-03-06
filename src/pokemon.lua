local fiber = require('fiber')
local avro = require('avro_schema')
local log = require('log')
local gis = require('gis')
gis.install()

local schema = {
    player = {
        type="record",
        name="player_schema",
        fields={
            {name="id", type="long"},
            {name="name", type="string"},
            {
                name="location",
                type= {
                    type="record",
                    name="player_location",
                    fields={
                        {name="x", type="double"},
                        {name="y", type="double"}
                    }
                }
            }
        }
    },
    pokemon = {
        type="record",
        name="pokemon_schema",
        fields={
            {name="id", type="long"},
            {name="status", type="string"},
            {name="name", type="string"},
            {name="chance", type="double"},
            {
                name="location",
                type= {
                    type="record",
                    name="pokemon_location",
                    fields={
                        {name="x", type="double"},
                        {name="y", type="double"}
                    }
                }
            }
        }
    }
}

local game = {
    wgs84 = 4326, -- WGS84 World-wide Projection (Lon/Lat)
    nationalmap = 2163, -- US National Atlas Equal Area projection (meters)
    catch_distance = 100,
    respawn_time = 60,
    state = {
        ACTIVE='active',
        CAUGHT='caught'
    },
    player_model = {},
    pokemon_model = {},

    ID = 1,
    STATUS = 2,

    -- pokemon respawn fiber
    respawn = function(self)
        fiber.name('Respawn fiber')
        while true do
            for _, tuple in box.space.pokemons.index.status:pairs(
                    self.state.CAUGHT) do
                box.space.pokemons:update(
                    tuple[self.ID],
                    {{'=', self.STATUS, self.state.ACTIVE}}
                )
            end
            fiber.sleep(self.respawn_time)
        end
    end,

    -- event notification
    notify = function(self, player, pokemon)
        log.info("Player '%s' caught '%s'", player.name, pokemon.name)
    end,

    -- create game object
    start = function(self)
        -- create spaces and indexes
        box.once('init', function()
            box.schema.create_space('pokemons')
            box.space.pokemons:create_index(
                "primary", {type = 'hash', parts = {1, 'unsigned'}}
            )
            box.space.pokemons:create_index(
                "status", {type = "tree", parts = {2, 'str'}}
            )
        end)

        -- create models
        local ok_m, pokemon = avro.create(schema.pokemon)
        local ok_p, player = avro.create(schema.player)
        if ok_m and ok_p then
            -- compile models
            local ok_cm, compiled_pokemon = avro.compile(pokemon)
            local ok_cp, compiled_player = avro.compile(player)
            if ok_cm and ok_cp then
                -- start the game
                self.pokemon_model = compiled_pokemon
                self.player_model = compiled_player
                fiber.create(self.respawn, self)
                log.info('Started')
                return true
            else
                log.error('Schema compilation failed')
            end
        else
            log.info('Schema creation failed')
        end
        return false
    end,

    -- return pokemons list in map
    map = function(self)
        local result = {}
        for _, tuple in box.space.pokemons.index.status:pairs(
                self.state.ACTIVE) do
            local ok, pokemon = self.pokemon_model.unflatten(tuple)
            table.insert(result, pokemon)
        end
        return result
    end,

    -- add pokemon to map and store it in Tarantool
    add_pokemon = function(self, pokemon)
        pokemon.status = self.state.ACTIVE
        local ok, tuple = self.pokemon_model.flatten(pokemon)
        if not ok then
            return false
        end
        box.space.pokemons:replace(tuple)
        return true
    end,

    -- catch pokemon in location
    catch = function(self, pokemon_id, player)
        -- check player data
        local ok, tuple = self.player_model.flatten(player)
        if not ok then
            return false
        end
        -- get pokemon data
        local p_tuple = box.space.pokemons:get(pokemon_id)
        if p_tuple == nil then
            return false
        end
        local ok, pokemon = self.pokemon_model.unflatten(p_tuple)
        if not ok then
            return false
        end
        if pokemon.status ~= self.state.ACTIVE then
            return false
        end
        local m_pos = gis.Point(
            {pokemon.location.x, pokemon.location.y}, self.wgs84
        ):transform(self.nationalmap)
        local p_pos = gis.Point(
            {player.location.x, player.location.y}, self.wgs84
        ):transform(self.nationalmap)

        -- check catch distance condition
        if p_pos:distance(m_pos) > self.catch_distance then
            return false
        end
        -- try to catch pokemon
        local caught = math.random(100) >= 100 - pokemon.chance
        if caught then
            -- update and notify on success
            box.space.pokemons:update(
                pokemon_id, {{'=', self.STATUS, self.state.CAUGHT}}
            )
            self:notify(player, pokemon)
        end
        return caught
    end
}

return game
