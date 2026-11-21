// Derived from spotr's src/core/page/agent.ts at a2f9d81. Runs inside Spotify's page.
(() => {
  const version = 1

  if (window.__bop?.version === version) return window.__bop

  // The object owning getRegistry() is passed down React's tree as a
  // context value, so walk the tree from the root element.
  const findPlatform = () => {
    const root = document.querySelector("#main") ?? document.body.firstElementChild

    if (!root) return undefined
    const entry = Object.entries(root).find(([key]) => key.startsWith("__reactContainer"))
    const start = entry?.[1]
    const stack = start ? [start] : []
    const seen = new Set()

    while (stack.length > 0) {
      const fiber = stack.pop()

      if (!fiber || seen.has(fiber)) continue
      seen.add(fiber)
      const value = fiber.memoizedProps?.value

      if (value?.getRegistry) return value

      if (value) {
        // The platform may sit one level down, e.g. { platform, ... }.
        const found = Object.values(value).find((candidate) => candidate?.getRegistry)

        if (found) return found
      }

      if (fiber.child) stack.push(fiber.child)

      if (fiber.sibling) stack.push(fiber.sibling)
    }

    return undefined
  }

  const registry = findPlatform()?.getRegistry?.()
  const notReady = { ok: false, kind: "NotReady", message: "Spotify's internal registry wasn't found" }

  // Spotify registers each API under a Symbol whose description is the
  // API's name, e.g. Symbol("PlayerAPI").
  const resolveApi = (name) => {
    if (!registry) return undefined
    const token = [...registry._map.keys()].find((key) => key?.description === name)

    return token ? registry.resolve(token) : undefined
  }

  const agent = {
    version,
    async dispatch(api, method, args) {
      if (!registry) return notReady
      const target = resolveApi(api)

      if (!target) return { ok: false, kind: "ApiMissing", message: `No internal API named ${api}` }
      const fn = target[method]

      if (!fn) return { ok: false, kind: "MethodMissing", message: `${api} has no method ${method}` }

      try {
        const value = await fn.call(target, ...args)

        // A JSON round trip turns Spotify's class instances into plain
        // data that survives the trip back over the DevTools socket.
        return { ok: true, value: value === undefined ? null : JSON.parse(JSON.stringify(value)) }
      } catch (error) {
        return { ok: false, kind: "Rejected", message: String(error) }
      }
    },
    // Spotify only reports Private Session through a subscription, which
    // calls back once with the current value.
    privateSession() {
      if (!registry) return Promise.resolve(notReady)
      const target = resolveApi("PrivateSessionAPI")

      if (!target) return Promise.resolve({ ok: false, kind: "ApiMissing", message: "No internal API named PrivateSessionAPI" })

      if (!target.subscribeToPrivateSession) {
        return Promise.resolve({ ok: false, kind: "MethodMissing", message: "PrivateSessionAPI has no method subscribeToPrivateSession" })
      }

      return new Promise((resolve) => {
        let unsubscribe
        let result

        const finish = (value) => {
          if (result) return
          result = value
          clearTimeout(timer)
          if (typeof unsubscribe === "function") unsubscribe()
          resolve(value)
        }

        const timer = setTimeout(() => finish({ ok: false, kind: "Rejected", message: "Spotify didn't report Private Session" }), 1000)

        try {
          unsubscribe = target.subscribeToPrivateSession((value) => finish(typeof value === "boolean"
            ? { ok: true, value }
            : { ok: false, kind: "Rejected", message: `Private Session was ${typeof value}` }))
          if (result && typeof unsubscribe === "function") unsubscribe()
        } catch (error) {
          finish({ ok: false, kind: "Rejected", message: String(error) })
        }
      })
    }
  }

  // Spotify may still be loading. Install again on the next call rather
  // than caching an agent that can't find the registry.
  if (registry) window.__bop = agent

  return agent
})
