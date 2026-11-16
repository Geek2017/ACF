// Bring the Agents window (Alacritty --class Agents) to the front. Loaded by `agents --window`.
var clients = workspace.clientList();
for (var i = 0; i < clients.length; i++) {
    var c = clients[i];
    if (String(c.resourceClass).toLowerCase() === "agents") {
        c.minimized = false;
        workspace.activeClient = c;
        break;
    }
}
