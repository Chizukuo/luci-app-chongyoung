module("luci.controller.chongyoung", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/chongyoung") then
		return
	end

	entry({"admin", "services", "chongyoung"}, view("chongyoung/general"), _("ChongYoung Network"), 60)
end
