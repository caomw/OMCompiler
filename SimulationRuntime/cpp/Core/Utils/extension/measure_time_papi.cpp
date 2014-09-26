#include <Core/Utils/extension/measure_time_papi.hpp>

MeasureTimeValuesPAPI::MeasureTimeValuesPAPI(unsigned long long time, long long l2CacheMisses, long long instructions) : MeasureTimeValues(), time(time), l2CacheMisses(l2CacheMisses), instructions(instructions), max_time(time) {}

MeasureTimeValuesPAPI::~MeasureTimeValuesPAPI() {}

std::string MeasureTimeValuesPAPI::serializeToJson() const
{
  std::stringstream ss;
  ss << "\"time\":" << time << ",\"maxTime\":" << max_time << ",\"l2cacheMisses\":" << l2CacheMisses << ",\"instructions\":" << instructions;
  return ss.str();
}

MeasureTimePAPI::MeasureTimePAPI() : MeasureTime()
{
  events = new int[NUM_PAPI_EVENTS];

#ifdef USE_PAPI
  events[0] = PAPI_TOT_CYC;
  events[1] = PAPI_L2_TCM;
  events[2] = PAPI_TOT_INS;

  eventSet = PAPI_NULL;
  int initRetVal = PAPI_library_init(PAPI_VER_CURRENT);

  if (initRetVal != PAPI_VER_CURRENT && initRetVal > 0)
  {
    std::cerr << "PAPI library init failed!" << std::endl;
    exit(1);
  }

  if (PAPI_create_eventset(&eventSet) != PAPI_OK)
  {
    std::cerr << "PAPI create eventset failed!" << " Error: " << PAPI_create_eventset(&eventSet) << std::endl;
    exit(1);
  }

  if (PAPI_add_events(eventSet, events, NUM_PAPI_EVENTS) != PAPI_OK)
  {
    std::cerr << "PAPI add events failed!" << std::endl;
    exit(1);
  }

  if (PAPI_start(eventSet) != PAPI_OK)
  {
    std::cerr << "PAPI_start_counters - FAILED" << std::endl;
    throw std::runtime_error("PAPI_start_counters - FAILED");
  }
#else
  eventSet = 0;
  throw std::runtime_error("Papi not supported!");
#endif
}

MeasureTimePAPI::~MeasureTimePAPI()
{

}

void MeasureTimePAPI::initializeThread(unsigned long int (*threadHandle)())
{
#ifdef USE_PAPI
  int threadNumber = threadHandle();

  if (PAPI_thread_init(threadHandle) != PAPI_OK)
    std::cerr << "PAPI thread init failed! Thread: " << threadNumber << std::endl;
#endif
}

void MeasureTimePAPI::deinitializeThread(unsigned long int (*threadHandle)())
{

}

void MeasureTimePAPI::getTimeValuesStartP(MeasureTimeValues *res)
{
#ifdef USE_PAPI
  MeasureTimeValuesPAPI *val = static_cast<MeasureTimeValuesPAPI*>(res);

  if (PAPI_reset(eventSet) != PAPI_OK)
  {
    std::cerr << "PAPI_reset - FAILED" << std::endl;
    throw std::runtime_error("PAPI_reset_counters - FAILED");
  }

  val->time = 0;
  val->l2CacheMisses = 0;
  val->instructions = 0;
#endif
}

void MeasureTimePAPI::getTimeValuesEndP(MeasureTimeValues *res)
{
#ifdef USE_PAPI
  long long values[NUM_PAPI_EVENTS];
  if (PAPI_read(eventSet, values) != PAPI_OK)
  {
          std::cerr << "PAPI_read_counters - FAILED" << std::endl;
          throw std::runtime_error("PAPI_read_counters - FAILED");
  }

  MeasureTimeValuesPAPI *val = static_cast<MeasureTimeValuesPAPI*>(res);
  val->time = values[0];
  val->l2CacheMisses = values[1];
  val->instructions = values[2];
#endif
}

MeasureTimeValues* MeasureTimePAPI::getZeroValuesP()
{
  return new MeasureTimeValuesPAPI(0, 0, 0);
}

void MeasureTimeValuesPAPI::add(MeasureTimeValues *values)
{
  MeasureTimeValuesPAPI *val = static_cast<MeasureTimeValuesPAPI*>(values);
  time += val->time;
  l2CacheMisses += val->l2CacheMisses;
  instructions += val->instructions;

  if( val->time > max_time )
    max_time = val->time;
}

void MeasureTimeValuesPAPI::sub(MeasureTimeValues *values)
{
  MeasureTimeValuesPAPI *val = static_cast<MeasureTimeValuesPAPI*>(values);
  if(time > val->time)
    time -= val->time;
  else
    time = 0;

  if(l2CacheMisses > val->l2CacheMisses)
    l2CacheMisses -= val->l2CacheMisses;
  else
    l2CacheMisses = 0;

  if(instructions > val->instructions)
    instructions -= val->instructions;
  else
    instructions = 0;
}

void MeasureTimeValuesPAPI::div(int counter)
{
  time = time / counter;
  l2CacheMisses = l2CacheMisses / counter;
  instructions = instructions / counter;
}
