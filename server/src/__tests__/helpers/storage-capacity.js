export const unrestrictedTestCapacity = {
  async reserve() {
    return { reservationBytes: null, identity: null };
  },
  async withWritePermit(_session, _sizeBytes, work) {
    return work();
  },
};
