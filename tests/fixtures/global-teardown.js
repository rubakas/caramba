const { shutdown } = require('./server')

module.exports = async () => {
  await shutdown()
}
