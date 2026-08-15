// FluxCapacitor push service worker: shows the notification and opens
// (or focuses) the console at the payload's path on click.
self.addEventListener("push", event => {
  let payload = {}
  try {
    payload = event.data ? event.data.json() : {}
  } catch (_error) {
    payload = {title: "FluxCapacitor", body: event.data && event.data.text()}
  }

  event.waitUntil(
    self.registration.showNotification(payload.title || "FluxCapacitor", {
      body: payload.body || "",
      data: {path: payload.path || "/console"},
      icon: "/favicon.svg",
    })
  )
})

self.addEventListener("notificationclick", event => {
  event.notification.close()
  const path = (event.notification.data && event.notification.data.path) || "/console"

  event.waitUntil(
    clients.matchAll({type: "window", includeUncontrolled: true}).then(list => {
      for (const client of list) {
        if (client.url.includes("/console") && "focus" in client) {
          client.navigate(path)
          return client.focus()
        }
      }
      return clients.openWindow(path)
    })
  )
})
