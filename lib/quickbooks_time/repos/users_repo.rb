# frozen_string_literal: true

class UsersRepo
  def initialize
    @data = {}
  end

  def upsert(user)
    id = user['id'] || user[:id]
    changed = @data[id] != user
    @data[id] = user
    changed
  end
end
