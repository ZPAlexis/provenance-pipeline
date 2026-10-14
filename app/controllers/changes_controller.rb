# What changed since a check of everything (1.4). Read-only.
class ChangesController < ApplicationController
  def index
    @points = WhatChanged.points
    @point = WhatChanged.point(params[:from])
    @changes = WhatChanged.new(@point.at)
  end
end
